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

const Vector3 = extern struct { x: f32, y: f32, z: f32 };

var virtual_calls: u32 = 0;
var virtual_hook: ?Hooks.Hook(fn (?*anyopaque) callconv(.c) ?*anyopaque) = null;

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
        error.IndexOutOfBounds => -25,
        error.SizeMismatch => -26,
        error.GenericMethodNotSupported => -27,
    };
}

fn toStringDetour(instance: ?*anyopaque) callconv(.c) ?*anyopaque {
    virtual_calls +%= 1;
    const hook = virtual_hook orelse return null;
    return hook.original(instance);
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

fn selftestVirtual(runtime_value: Runtime) i32 {
    const text = zil2cpp.String.fromUtf8(runtime_value, "virtual-hook") catch return -30;
    const object_class = runtime_value.findClass("System", "Object") catch return -31;
    const base_method = object_class.findMethod("ToString", 0) catch return -32;
    if (!base_method.isVirtual()) return -33;
    const resolved = base_method.resolveVirtual(text.pointer) catch return -34;
    if (resolved.pointer == base_method.pointer) return -35;
    virtual_hook = Hooks.hookMethod(fn (?*anyopaque) callconv(.c) ?*anyopaque, resolved, &toStringDetour) catch return -36;
    const returned = resolved.invokeOn(text.pointer, .{}, ?*anyopaque) catch return -37;
    const calls = virtual_calls;
    virtual_hook.?.detach();
    virtual_hook = null;
    if (calls != 1) return -38;
    const returned_text = zil2cpp.String{ .runtime = runtime_value, .pointer = returned };
    var buffer: [64]u8 = undefined;
    const written = returned_text.toUtf8(buffer[0..]) catch return -39;
    if (!std.mem.eql(u8, written, "virtual-hook")) return -40;
    return 1;
}

fn selftestStructReturn(runtime_value: Runtime) i32 {
    const vector_class = runtime_value.findClass("UnityEngine", "Vector3") catch return -70;
    const one_method = vector_class.findMethod("get_one", 0) catch return -71;
    const one = one_method.invoke(.{}, Vector3) catch return -72;
    if (one.x != 1 or one.y != 1 or one.z != 1) return -73;
    return 1;
}

fn selftestStructArgs(runtime_value: Runtime) i32 {
    const vector_class = runtime_value.findClass("UnityEngine", "Vector3") catch return -74;
    const dot_method = vector_class.findMethod("Dot", 2) catch return -75;
    const left = Vector3{ .x = 1, .y = 2, .z = 3 };
    const right = Vector3{ .x = 4, .y = 5, .z = 6 };
    const dot = dot_method.invoke(.{ left, right }, f32) catch return -76;
    if (dot != 32) return -77;
    return 1;
}

fn selftestMethods(runtime_value: Runtime) i32 {
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -80;
    var screen_methods = screen.methods();
    var found_width = false;
    var screen_count: u32 = 0;
    while (screen_methods.next()) |method| {
        screen_count += 1;
        const name = method.name() orelse continue;
        if (std.mem.eql(u8, std.mem.span(name), "get_width") and method.parameterCount() == 0) found_width = true;
    }
    if (screen_count == 0) return -81;
    if (!found_width) return -82;

    const vector = runtime_value.findClass("UnityEngine", "Vector3") catch return -83;
    var vector_methods = vector.methods();
    var found_dot = false;
    while (vector_methods.next()) |method| {
        const name = method.name() orelse continue;
        if (std.mem.eql(u8, std.mem.span(name), "Dot") and method.parameterCount() == 2) found_dot = true;
    }
    if (!found_dot) return -84;
    return 1;
}

fn selftestArrays(runtime_value: Runtime) i32 {
    const int_class = runtime_value.findClass("System", "Int32") catch return -110;
    const numbers = int_class.newArray(4) catch return -111;
    inline for (0..4) |index| {
        numbers.set(i32, index, @as(i32, @intCast(index * 10 + 10))) catch return -112;
    }
    inline for (0..4) |index| {
        const expected: i32 = @intCast(index * 10 + 10);
        const actual = numbers.get(i32, index) catch return -113;
        if (actual != expected) return -114;
    }

    const string_class = runtime_value.findClass("System", "String") catch return -115;
    const names = string_class.newArray(2) catch return -116;
    const text = zil2cpp.String.fromUtf8(runtime_value, "array-string") catch return -117;
    names.set(?*anyopaque, 0, text.pointer) catch return -118;
    names.set(?*anyopaque, 1, null) catch return -119;
    const stored = names.get(?*anyopaque, 0) catch return -120;
    if (stored == null) return -121;
    const stored_text = zil2cpp.String{ .runtime = runtime_value, .pointer = stored };
    var buffer: [64]u8 = undefined;
    const written = stored_text.toUtf8(buffer[0..]) catch return -122;
    if (!std.mem.eql(u8, written, "array-string")) return -123;
    const empty = names.get(?*anyopaque, 1) catch return -124;
    if (empty != null) return -125;
    return 1;
}

fn selftestGenerics(runtime_value: Runtime) i32 {
    const text = zil2cpp.String.fromUtf8(runtime_value, "generic-class") catch return -130;
    const text_class = runtime_value.classOf(text.pointer) catch return -131;
    const class_name = text_class.name() orelse return -132;
    if (!std.mem.eql(u8, std.mem.span(class_name), "String")) return -133;

    const list = runtime_value.findClass("System.Collections.Generic", "List`1") catch return -134;
    if (!list.isGeneric()) return -135;
    const array_class = runtime_value.findClass("System", "Array") catch return -139;
    var methods = array_class.methods();
    var generic_method = false;
    while (methods.next()) |method| {
        if (method.isGeneric()) {
            generic_method = true;
            const outcome = method.invoke(.{}, void);
            if (outcome) |_| return -136 else |err| {
                if (err != error.GenericMethodNotSupported) return -137;
            }
            break;
        }
    }
    if (!generic_method) return -138;
    return 1;
}

export fn dev_selftest_generics() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestGenerics(runtime_value);
}

export fn dev_selftest_arrays() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestArrays(runtime_value);
}

export fn dev_selftest_methods() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestMethods(runtime_value);
}

export fn dev_selftest_struct_return() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestStructReturn(runtime_value);
}

export fn dev_selftest_struct_args() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestStructArgs(runtime_value);
}

export fn dev_selftest_static() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestStatic(runtime_value);
}

export fn dev_selftest_virtual() callconv(.c) i32 {
    Hooks.init() catch return -1;
    const runtime_value = runtime() catch |err| return errorCode(err);
    return selftestVirtual(runtime_value);
}

export fn dev_virtual_calls() callconv(.c) u32 {
    return virtual_calls;
}

fn selftestStatic(runtime_value: Runtime) i32 {
    const string_class = runtime_value.findClass("System", "String") catch return -50;
    const empty_field = string_class.findField("Empty") catch return -51;
    if (!empty_field.isStatic()) return -52;
    const value = empty_field.readStatic(?*anyopaque) catch return -53;
    if (value == null) return -54;
    const text = zil2cpp.String{ .runtime = runtime_value, .pointer = value };
    if ((text.length() catch return -55) != 0) return -56;

    const image = runtime_value.findImage("Assembly-CSharp.dll") catch return -57;
    var class_index: usize = 0;
    while (class_index < image.classCount()) : (class_index += 1) {
        const klass = image.classAt(class_index) catch continue;
        if (klass.isGeneric() or klass.isInflated()) continue;
        var fields = klass.fields();
        while (fields.next()) |field| {
            if (!field.isStatic()) continue;
            const flags = runtime_value.exports.field_get_flags(field.pointer);
            if ((flags & 0x0060) != 0) continue;
            const type_name = field.typeName() orelse continue;
            if (!std.mem.eql(u8, std.mem.span(type_name), "System.Int32")) continue;
            const original = field.readStatic(i32) catch continue;
            field.writeStatic(@as(i32, original +% 1)) catch continue;
            const updated = field.readStatic(i32) catch continue;
            field.writeStatic(original) catch continue;
            if (updated == original +% 1) return 1;
        }
    }
    return -58;
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
