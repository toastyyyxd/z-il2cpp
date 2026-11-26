const std = @import("std");
const zil2cpp = @import("z_il2cpp");
const MinHook = zil2cpp.MinHook;
const Runtime = zil2cpp.Runtime;
const Loader = zil2cpp.Loader;
const Error = zil2cpp.Error;

extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, parameter: ?*anyopaque, flags: u32, thread_id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, creation: u32, attributes: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(handle: ?*anyopaque, buffer: [*]const u8, length: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) c_int;

const game_assembly = [16:0]u16{
    'G', 'a', 'm', 'e', 'A', 's', 's', 'e', 'm', 'b', 'l', 'y', '.', 'd', 'l', 'l',
};
const stage_name = std.unicode.utf8ToUtf16LeStringLiteral("zil2cpp-stage.txt");
const result_name = std.unicode.utf8ToUtf16LeStringLiteral("zil2cpp-native-result.json");

var scratch: [8192]u8 align(16) = @splat(0);
var started = false;
var init_returned = false;
var startup_mode: []const u8 = "unknown";
var init_hook: ?MinHook.TypedHook(fn ([*:0]const u8) callconv(.c) c_int) = null;

var frame_calls: u32 = 0;
var frame_slots: u32 = 0;
const frame_hook_limit = 8;

fn FrameSlot(comptime _: usize) type {
    return struct {
        var hook: ?MinHook.TypedHook(fn (?*anyopaque) callconv(.c) void) = null;
        fn detour(instance: ?*anyopaque) callconv(.c) void {
            frame_calls +%= 1;
            if (hook) |*active| active.original(instance);
        }
    };
}

const frame_detours = blk: {
    var result: [frame_hook_limit]*const fn (?*anyopaque) callconv(.c) void = undefined;
    for (0..frame_hook_limit) |index| {
        result[index] = &FrameSlot(index).detour;
    }
    break :blk result;
};

fn writeFile(name: [:0]const u16, data: []const u8) void {
    const handle = CreateFileW(name.ptr, 0x40000000, 0, null, 2, 0x80, null) orelse return;
    var written: u32 = 0;
    _ = WriteFile(handle, data.ptr, @intCast(data.len), &written, null);
    _ = CloseHandle(handle);
}

fn writeStage(stage: []const u8) void {
    writeFile(stage_name, stage);
}

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

fn widthOf(runtime_value: Runtime) i32 {
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -100;
    const method = screen.findMethod("get_width", 0) catch return -101;
    return method.invoke(.{}, i32) catch return -102;
}

fn methodCodePointer(method_info: ?*anyopaque) ?*anyopaque {
    const info = method_info orelse return null;
    const bytes: [*]const u8 = @ptrCast(info);
    const candidate = @as(*align(1) const usize, @ptrCast(bytes)).*;
    if (candidate == 0) return null;
    return @ptrFromInt(candidate);
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
    return (runtime_value.exports.method_get_flags(method, &iflags) & 0x0010) != 0;
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

fn installFrameHooks(runtime_value: Runtime) u32 {
    const domain = runtime_value.domain orelse return 0;
    var assembly_count: usize = 0;
    const assemblies = runtime_value.exports.domain_get_assemblies(domain, &assembly_count);
    var installed: u32 = 0;
    var assembly_index: usize = 0;
    while (assembly_index < assembly_count and installed < frame_hook_limit) : (assembly_index += 1) {
        const image = runtime_value.exports.assembly_get_image(assemblies[assembly_index]) orelse continue;
        const image_name = runtime_value.exports.image_get_name(image) orelse continue;
        if (!std.mem.eql(u8, std.mem.span(image_name), "Assembly-CSharp.dll")) continue;
        const class_count = runtime_value.exports.image_get_class_count(image);
        var class_index: usize = 0;
        while (class_index < class_count and installed < frame_hook_limit) : (class_index += 1) {
            const klass = runtime_value.exports.image_get_class(image, class_index) orelse continue;
            if (!isMonoBehaviour(runtime_value, klass)) continue;
            if (runtime_value.exports.class_is_generic(klass)) continue;
            if (runtime_value.exports.class_is_inflated(klass)) continue;
            const method = runtime_value.exports.class_get_method_from_name(klass, "Update", 0) orelse continue;
            if (isStaticMethod(runtime_value, method)) continue;
            if (runtime_value.exports.method_is_generic(method)) continue;
            if (runtime_value.exports.method_is_inflated(method)) continue;
            const address = methodCodePointer(method) orelse continue;
            if (installFrameSlot(installed, address)) installed += 1;
        }
    }
    return installed;
}

fn writeResult(ok: bool, stage: []const u8, width: i32, hooks: u32) void {
    var buffer: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buffer, "{{\"ok\": {s}, \"stage\": \"{s}\", \"mode\": \"{s}\", \"width\": {d}, \"hooks\": {d}, \"frames\": {d}}}\n", .{
        if (ok) "true" else "false",
        stage,
        startup_mode,
        width,
        hooks,
        frame_calls,
    }) catch return;
    writeFile(result_name, json);
}

fn bootstrapThread(_: ?*anyopaque) callconv(.winapi) u32 {
    Sleep(500);
    writeStage("bootstrap");
    const runtime_value = runtime() catch |err| {
        writeStage("runtime-fail");
        writeResult(false, "runtime", errorCode(err), 0);
        return 0;
    };
    writeStage("runtime-ok");
    const width = widthOf(runtime_value);
    if (width <= 0) {
        writeStage("width-fail");
        writeResult(false, "width", width, 0);
        return 0;
    }
    writeStage("width-ok");
    const hooks = installFrameHooks(runtime_value);
    frame_slots = hooks;
    writeStage("frame-hooks");
    Sleep(3000);
    writeResult(hooks > 0, "done", width, hooks);
    writeStage("done");
    return 0;
}

fn startBootstrap() void {
    _ = CreateThread(null, 0, &bootstrapThread, null, 0, null);
}

fn il2cppInitDetour(domain: [*:0]const u8) callconv(.c) c_int {
    const hook = init_hook orelse return 0;
    const result = hook.original(domain);
    init_returned = true;
    return result;
}

fn startupThread(_: ?*anyopaque) callconv(.winapi) u32 {
    writeStage("start");
    var module: ?*anyopaque = null;
    var tries: u32 = 0;
    while (tries < 30000) : (tries += 1) {
        module = GetModuleHandleW(&game_assembly);
        if (module != null) break;
        Sleep(1);
    }
    if (module == null) {
        writeStage("no-gameassembly");
        writeResult(false, "gameassembly", 0, 0);
        return 0;
    }
    writeStage("gameassembly");
    MinHook.init() catch {
        writeStage("minhook-fail");
        writeResult(false, "minhook", 0, 0);
        return 0;
    };
    if (GetProcAddress(module, "il2cpp_init")) |raw| {
        init_hook = MinHook.TypedHook(fn ([*:0]const u8) callconv(.c) c_int).install(raw, &il2cppInitDetour) catch null;
    }
    writeStage("hooked");
    var waited: u32 = 0;
    while (!init_returned and waited < 100) : (waited += 1) {
        Sleep(50);
    }
    if (init_returned) {
        startup_mode = "init-hook";
        writeStage("init-returned");
    } else {
        startup_mode = "timeout";
        writeStage("init-timeout");
    }
    startBootstrap();
    return 0;
}

export fn zil2cpp_start() callconv(.c) c_int {
    if (started) return 1;
    started = true;
    _ = CreateThread(null, 0, &startupThread, null, 0, null);
    return 1;
}
