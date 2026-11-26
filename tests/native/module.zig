const std = @import("std");
const zil2cpp = @import("z_il2cpp");
const frames = @import("frames");
const Hooks = zil2cpp.Hooks;
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
const exception_name = std.unicode.utf8ToUtf16LeStringLiteral("zil2cpp-exception.txt");

var scratch: [8192]u8 align(16) = @splat(0);
var started = false;
var init_returned = false;
var startup_mode: []const u8 = "unknown";
var exception_status: i32 = 0;
var init_hook: ?Hooks.Hook(fn ([*:0]const u8) callconv(.c) c_int) = null;

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
        error.ImageNotFound => -24,
        error.IndexOutOfBounds => -25,
        error.SizeMismatch => -26,
        error.GenericMethodNotSupported => -27,
        error.HookUnsupported => -28,
        error.HookNoMemory => -29,
        error.HookProtectFailed => -30,
        error.HookWriteFailed => -31,
    };
}

fn widthOf(runtime_value: Runtime) i32 {
    const screen = runtime_value.findClass("UnityEngine", "Screen") catch return -100;
    const method = screen.findMethod("get_width", 0) catch return -101;
    return method.invoke(.{}, i32) catch return -102;
}

fn writeResult(ok: bool, stage: []const u8, width: i32, hooks: u32) void {
    var buffer: [512]u8 = undefined;
    const json = std.fmt.bufPrint(&buffer, "{{\"ok\": {s}, \"stage\": \"{s}\", \"mode\": \"{s}\", \"width\": {d}, \"hooks\": {d}, \"frames\": {d}, \"exception\": {d}}}\n", .{
        if (ok) "true" else "false",
        stage,
        startup_mode,
        width,
        hooks,
        frames.count(),
        exception_status,
    }) catch return;
    writeFile(result_name, json);
}

fn exceptionTest(runtime_value: Runtime) i32 {
    const string_class = runtime_value.findClass("System", "String") catch return -110;
    const chars = string_class.findMethod("get_Chars", 1) catch return -111;
    const text = zil2cpp.String.fromUtf8(runtime_value, "abc") catch return -112;
    const outcome = chars.invokeOnCatching(text.pointer, .{@as(i32, 99)}, u16) catch return -113;
    const exception = switch (outcome) {
        .value => return -114,
        .exception => |value| value,
    };
    const class_name = exception.className() orelse return -115;
    var message_buffer: [256]u8 = undefined;
    const message = exception.message(message_buffer[0..]) catch return -116;
    var trace_buffer: [512]u8 = undefined;
    const trace = exception.stackTrace(trace_buffer[0..]) catch return -117;
    if (message.len == 0 or trace.len == 0) return -118;
    var output: [1024]u8 = undefined;
    const text_output = std.fmt.bufPrint(&output, "{s}\n{s}\n{s}\n", .{ std.mem.span(class_name), message, trace }) catch return -119;
    writeFile(exception_name, text_output);
    return 1;
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
    exception_status = exceptionTest(runtime_value);
    if (exception_status != 1) {
        writeStage("exception-fail");
        writeResult(false, "exception", width, 0);
        return 0;
    }
    writeStage("exception-ok");
    const hooks = frames.install(runtime_value, frames.limit);
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
    Hooks.init() catch {
        writeStage("minhook-fail");
        writeResult(false, "minhook", 0, 0);
        return 0;
    };
    if (GetProcAddress(module, "il2cpp_init")) |raw| {
        const init_signature = fn ([*:0]const u8) callconv(.c) c_int;
        init_hook = Hooks.Hook(init_signature).install(raw, &il2cppInitDetour) catch null;
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
