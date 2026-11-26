const std = @import("std");

const winhttp_orig = [16:0]u16{
    'w', 'i', 'n', 'h', 't', 't', 'p', '_', 'o', 'r', 'i', 'g', '.', 'd', 'l', 'l',
};

const zil2cpp_name = [11:0]u16{ 'z', 'i', 'l', '2', 'c', 'p', 'p', '.', 'd', 'l', 'l' };

extern "kernel32" fn LoadLibraryW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CreateThread(attributes: ?*anyopaque, stack_size: usize, start: *const fn (?*anyopaque) callconv(.winapi) u32, parameter: ?*anyopaque, flags: u32, thread_id: ?*u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;
extern "kernel32" fn CreateFileW(name: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, creation: u32, attributes: u32, template: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(handle: ?*anyopaque, buffer: [*]const u8, length: u32, written: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) c_int;

const stage_name = std.unicode.utf8ToUtf16LeStringLiteral("winhttp-proxy-stage.txt");

const Function = *const fn () callconv(.winapi) usize;

var loaded = false;
var original_module: ?*anyopaque = null;
var function_count: usize = 0;
var function_table: [4]?*anyopaque = .{ null, null, null, null };

fn writeStage(stage: []const u8) void {
    const handle = CreateFileW(stage_name, 0x40000000, 0, null, 2, 0x80, null) orelse return;
    var written: u32 = 0;
    _ = WriteFile(handle, stage.ptr, @intCast(stage.len), &written, null);
    _ = CloseHandle(handle);
}

fn ensureLoaded() void {
    if (loaded) return;
    loaded = true;
    writeStage("original");
    original_module = LoadLibraryW(&winhttp_orig);
}

fn loadZil2cpp() void {
    writeStage("load-zil2cpp");
    const module = LoadLibraryW(&zil2cpp_name) orelse {
        writeStage("load-failed");
        return;
    };
    writeStage("loaded");
    if (GetProcAddress(module, "zil2cpp_start")) |start| {
        const call: *const fn () callconv(.c) c_int = @ptrCast(@alignCast(start));
        _ = call();
        writeStage("start-called");
    } else writeStage("no-start");
}

fn bootstrapThread(_: ?*anyopaque) callconv(.winapi) u32 {
    Sleep(1);
    writeStage("thread");
    loadZil2cpp();
    return 0;
}

export fn DllMain(instance: ?*anyopaque, reason: u32, reserved: ?*anyopaque) callconv(.winapi) c_int {
    _ = instance;
    _ = reserved;
    if (reason == 1) {
        _ = CreateThread(null, 0, &bootstrapThread, null, 0, null);
    }
    return 1;
}

fn resolve(name: [*:0]const u8) ?*anyopaque {
    ensureLoaded();
    const module = original_module orelse return null;
    const function = GetProcAddress(module, name) orelse return null;
    return function;
}

export fn WinHttpOpen(
    agent: ?[*:0]const u16,
    access_type: u32,
    proxy: ?[*:0]const u16,
    proxy_bypass: ?[*:0]const u16,
    flags: u32,
) callconv(.winapi) ?*anyopaque {
    const raw = resolve("WinHttpOpen") orelse return null;
    const call: *const fn (?[*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?*anyopaque = @ptrCast(@alignCast(raw));
    return call(agent, access_type, proxy, proxy_bypass, flags);
}

export fn WinHttpGetProxyForUrl(
    session: ?*anyopaque,
    url: ?[*:0]const u16,
    options: ?*anyopaque,
    info: ?*anyopaque,
) callconv(.winapi) c_int {
    const raw = resolve("WinHttpGetProxyForUrl") orelse return 0;
    const call: *const fn (?*anyopaque, ?[*:0]const u16, ?*anyopaque, ?*anyopaque) callconv(.winapi) c_int = @ptrCast(@alignCast(raw));
    return call(session, url, options, info);
}

export fn WinHttpGetIEProxyConfigForCurrentUser(config: ?*anyopaque) callconv(.winapi) c_int {
    const raw = resolve("WinHttpGetIEProxyConfigForCurrentUser") orelse return 0;
    const call: *const fn (?*anyopaque) callconv(.winapi) c_int = @ptrCast(@alignCast(raw));
    return call(config);
}

export fn WinHttpCloseHandle(handle: ?*anyopaque) callconv(.winapi) c_int {
    const raw = resolve("WinHttpCloseHandle") orelse return 0;
    const call: *const fn (?*anyopaque) callconv(.winapi) c_int = @ptrCast(@alignCast(raw));
    return call(handle);
}
