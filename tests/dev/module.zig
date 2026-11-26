const std = @import("std");
const zil2cpp = @import("z_il2cpp");
const MinHook = zil2cpp.MinHook;
const Runtime = zil2cpp.Runtime;
const Loader = zil2cpp.Loader;
const Error = zil2cpp.Error;

extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

var scratch: [8192]u8 align(16) = @splat(0);

var width_calls: u32 = 0;
var width_offset: usize = 0;
var width_before: i32 = 0;
var width_after: i32 = 0;
var width_final: i32 = 0;
var width_hook: ?MinHook.TypedHook(fn () callconv(.c) i32) = null;

var instance_calls: u32 = 0;
var instance_hook: ?MinHook.TypedHook(fn (?*anyopaque) callconv(.c) f32) = null;
var arg_calls: u32 = 0;
var frame_calls: u32 = 0;
var frame_slots: u32 = 0;
var frame_skip_original = false;
var frame_slot_counts: [frame_hook_limit]u32 = @splat(0);
const frame_hook_limit = 16;

fn FrameSlot(comptime index: usize) type {
    return struct {
        var hook: ?MinHook.TypedHook(fn (?*anyopaque) callconv(.c) void) = null;
        fn detour(instance: ?*anyopaque) callconv(.c) void {
            frame_calls +%= 1;
            frame_slot_counts[index] +%= 1;
            if (frame_skip_original) return;
            if (hook) |*active| active.original(instance);
        }
    };
}

const frame_detours = blk: {
    var result: [frame_hook_limit]*const fn () callconv(.c) void = undefined;
    for (0..frame_hook_limit) |index| {
        result[index] = &FrameSlot(index).detour;
    }
    break :blk result;
};
var arg_seen: f32 = 0;
var arg_before: f32 = 0;
var arg_after: f32 = 0;
var arg_final: f32 = 0;
var arg_hook: ?MinHook.TypedHook(fn (f32) callconv(.c) void) = null;

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

fn methodCodePointer(method_info: ?*anyopaque, offset: usize) ?*anyopaque {
    const info = method_info orelse return null;
    const bytes: [*]const u8 = @ptrCast(info);
    const candidate = @as(*align(1) const usize, @ptrCast(bytes + offset)).*;
    if (candidate == 0) return null;
    return @ptrFromInt(candidate);
}

fn fieldOfViewDetour(instance: ?*anyopaque) callconv(.c) f32 {
    instance_calls +%= 1;
    const hook = instance_hook orelse return -1;
    return hook.original(instance);
}

fn installWidthHook(runtime_value: Runtime, method_info: ?*anyopaque, offset: usize) bool {
    const address = methodCodePointer(method_info, offset) orelse return false;
    width_hook = MinHook.TypedHook(fn () callconv(.c) i32).install(address, &widthDetour) catch return false;
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return false;
    const method = screen.findMethod("get_width", 0) catch return false;
    const attempt = method.invoke(.{}, i32) catch return false;
    if (width_calls > 0 and attempt == width_before) {
        width_offset = offset;
        return true;
    }
    width_hook.?.detach();
    width_hook = null;
    return false;
}

fn selftestWidth(runtime_value: Runtime) i32 {
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -3;
    const method = screen.findMethod("get_width", 0) catch return -4;
    width_before = method.invoke(.{}, i32) catch return -5;
    if (width_before <= 0) return -5;
    var installed = false;
    for ([_]usize{ 0, 8 }) |offset| {
        if (installWidthHook(runtime_value, method.pointer, offset)) {
            installed = true;
            break;
        }
    }
    if (!installed) return -6;
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
    const address = methodCodePointer(setter.pointer, 0) orelse return -14;
    arg_hook = MinHook.TypedHook(fn (f32) callconv(.c) void).install(address, &timeScaleDetour) catch return -15;
    setter.invoke(.{@as(f32, 0.5)}, void) catch return -16;
    arg_after = getter.invoke(.{}, f32) catch return -17;
    const seen = arg_seen;
    const calls = arg_calls;
    arg_hook.?.detach();
    arg_hook = null;
    setter.invoke(.{arg_before}, void) catch return -18;
    arg_final = getter.invoke(.{}, f32) catch return -19;
    if (calls != 1 or seen != 0.5 or arg_after != 0.5) return -20;
    return 1;
}

fn selftestInstance(runtime_value: Runtime) i32 {
    const camera_class = runtime_value.findClass("UnityEngine", "Camera") catch return -30;
    const main_method = camera_class.findMethod("get_main", 0) catch return -31;
    const camera = main_method.invoke(.{}, ?*anyopaque) catch return -32;
    if (camera == null) return -33;
    const fov_method = camera_class.findMethod("get_fieldOfView", 0) catch return -34;
    const expected = fov_method.invokeOn(camera, .{}, f32) catch return -35;
    const address = methodCodePointer(fov_method.pointer, 0) orelse return -36;
    instance_hook = MinHook.TypedHook(fn (?*anyopaque) callconv(.c) f32).install(address, &fieldOfViewDetour) catch return -37;
    const actual = fov_method.invokeOn(camera, .{}, f32) catch return -38;
    const calls = instance_calls;
    instance_hook.?.detach();
    instance_hook = null;
    if (calls != 1 or actual != expected) return -39;
    return 1;
}

export fn dev_selftest_instance() callconv(.c) i32 {
    MinHook.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    const status = selftestInstance(runtime_value);
    MinHook.deinit() catch return -2;
    return status;
}

export fn dev_selftest_width() callconv(.c) i32 {
    MinHook.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    const status = selftestWidth(runtime_value);
    MinHook.deinit() catch return -2;
    return status;
}

export fn dev_selftest_args() callconv(.c) i32 {
    MinHook.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    const status = selftestArguments(runtime_value);
    MinHook.deinit() catch return -2;
    return status;
}

fn installFrameSlot(slot: usize, address: ?*anyopaque) bool {
    if (address == null) return false;
    const signature = fn (?*anyopaque) callconv(.c) void;
    var installed_here = false;
    inline for (0..frame_hook_limit) |index| {
        if (slot == index) {
            FrameSlot(index).hook = MinHook.TypedHook(signature).install(address.?, &FrameSlot(index).detour) catch return false;
            installed_here = true;
        }
    }
    return installed_here;
}

fn isMonoBehaviour(runtime_value: Runtime, klass: ?*anyopaque) bool {
    var current = klass;
    var depth: u32 = 0;
    while (current != null and depth < 32) : (depth += 1) {
        const name = runtime_value.exports.class_get_name(current) orelse break;
        if (std.mem.eql(u8, std.mem.span(name), "MonoBehaviour")) return true;
        current = runtime_value.exports.class_get_parent(current);
    }
    return false;
}

fn isStaticMethod(runtime_value: Runtime, method: ?*anyopaque) bool {
    var iflags: u32 = 0;
    const flags = runtime_value.exports.method_get_flags(method, &iflags);
    return (flags & 0x0010) != 0;
}

fn installFrameHooks(runtime_value: Runtime, limit: u32) u32 {
    const domain = runtime_value.domain orelse return 0;
    var assembly_count: usize = 0;
    const assemblies = runtime_value.exports.domain_get_assemblies(domain, &assembly_count);
    var installed: u32 = 0;
    var assembly_index: usize = 0;
    const effective_limit = @min(frame_hook_limit, limit);
    while (assembly_index < assembly_count and installed < effective_limit) : (assembly_index += 1) {
        const image = runtime_value.exports.assembly_get_image(assemblies[assembly_index]) orelse continue;
        const image_name = runtime_value.exports.image_get_name(image) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(image_name), "Assembly-CSharp.dll")) continue;
        const class_count = runtime_value.exports.image_get_class_count(image);
        var class_index: usize = 0;
        while (class_index < class_count and installed < effective_limit) : (class_index += 1) {
            const klass = runtime_value.exports.image_get_class(image, class_index) orelse continue;
            if (!isMonoBehaviour(runtime_value, klass)) continue;
            if (runtime_value.exports.class_is_generic(klass)) continue;
            if (runtime_value.exports.class_is_inflated(klass)) continue;
            const method = runtime_value.exports.class_get_method_from_name(klass, "Update", 0) orelse continue;
            if (isStaticMethod(runtime_value, method)) continue;
            if (runtime_value.exports.method_is_generic(method)) continue;
            if (runtime_value.exports.method_is_inflated(method)) continue;
            const address = methodCodePointer(method, 0) orelse continue;
            if (installFrameSlot(installed, address)) installed += 1;
        }
    }
    frame_slots = installed;
    return installed;
}

export fn dev_frame_skip_original(enable: u32) callconv(.c) void {
    frame_skip_original = enable != 0;
}

export fn dev_frame_slot_count(index: u32) callconv(.c) u32 {
    if (index >= frame_hook_limit) return 0;
    return frame_slot_counts[index];
}

export fn dev_frame_reset() callconv(.c) void {
    frame_calls = 0;
    frame_slot_counts = @splat(0);
}

export fn dev_frame_install_limit(limit: u32) callconv(.c) i32 {
    if (frame_slots != 0) return @intCast(frame_slots);
    MinHook.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    const installed = installFrameHooks(runtime_value, limit);
    if (installed == 0) return -2;
    return @intCast(installed);
}

export fn dev_frame_install() callconv(.c) i32 {
    return dev_frame_install_limit(frame_hook_limit);
}

export fn dev_frame_count() callconv(.c) u32 {
    return frame_calls;
}

export fn dev_frame_slots() callconv(.c) u32 {
    return frame_slots;
}

export fn dev_frame_remove() callconv(.c) i32 {
    inline for (0..frame_hook_limit) |index| {
        if (FrameSlot(index).hook) |*hook| {
            hook.detach();
            FrameSlot(index).hook = null;
        }
    }
    frame_slots = 0;
    MinHook.deinit() catch return -1;
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
    return width_calls;
}

export fn dev_offset() callconv(.c) usize {
    return width_offset;
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
