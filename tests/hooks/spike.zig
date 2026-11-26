const MH_OK: c_int = 0;

extern fn MH_Initialize() callconv(.winapi) c_int;
extern fn MH_Uninitialize() callconv(.winapi) c_int;
extern fn MH_CreateHook(target: ?*anyopaque, detour: ?*anyopaque, original: ?*?*anyopaque) callconv(.winapi) c_int;
extern fn MH_EnableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_DisableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_RemoveHook(target: ?*anyopaque) callconv(.winapi) c_int;

extern "kernel32" fn GetModuleHandleW(name: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: ?*anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const game_assembly = [16:0]u16{
    'G', 'a', 'm', 'e', 'A', 's', 's', 'e', 'm', 'b', 'l', 'y', '.', 'd', 'l', 'l',
};

var call_count: u32 = 0;
var installed = false;
var original: ?*const fn () callconv(.c) ?*anyopaque = null;

fn detour() callconv(.c) ?*anyopaque {
    call_count +%= 1;
    const function = original orelse return null;
    return function();
}

export fn spike_install() callconv(.c) i32 {
    if (installed) return 1;
    const module = GetModuleHandleW(&game_assembly) orelse return -1;
    const target = GetProcAddress(module, "il2cpp_domain_get") orelse return -2;
    if (MH_Initialize() != MH_OK) return -3;
    if (MH_CreateHook(target, @ptrCast(@constCast(&detour)), @ptrCast(&original)) != MH_OK) return -4;
    if (MH_EnableHook(target) != MH_OK) return -5;
    installed = true;
    return 1;
}

export fn spike_count() callconv(.c) u32 {
    return call_count;
}

export fn spike_remove() callconv(.c) i32 {
    if (!installed) return 1;
    const module = GetModuleHandleW(&game_assembly) orelse return -1;
    const target = GetProcAddress(module, "il2cpp_domain_get") orelse return -2;
    _ = MH_DisableHook(target);
    _ = MH_RemoveHook(target);
    _ = MH_Uninitialize();
    installed = false;
    return 1;
}
