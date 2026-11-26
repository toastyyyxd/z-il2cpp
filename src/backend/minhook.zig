const Error = @import("../error.zig").Error;

const MH_OK: c_int = 0;

extern fn MH_Initialize() callconv(.winapi) c_int;
extern fn MH_Uninitialize() callconv(.winapi) c_int;
extern fn MH_CreateHook(target: ?*anyopaque, detour: ?*anyopaque, original: ?*?*anyopaque) callconv(.winapi) c_int;
extern fn MH_EnableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_DisableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_RemoveHook(target: ?*anyopaque) callconv(.winapi) c_int;

var initialized = false;

pub fn init() Error!void {
    if (initialized) return;
    try check(MH_Initialize());
    initialized = true;
}

pub fn deinit() Error!void {
    return;
}

pub fn attach(target: ?*anyopaque, detour: ?*anyopaque) Error!*const anyopaque {
    var original: ?*anyopaque = null;
    try check(MH_CreateHook(target, detour, &original));
    try check(MH_EnableHook(target));
    return @ptrCast(@alignCast(original orelse return error.HookFailed));
}

pub fn detach(target: ?*anyopaque) void {
    _ = MH_DisableHook(target);
    _ = MH_RemoveHook(target);
}

fn check(status: c_int) Error!void {
    if (status != MH_OK) return error.HookFailed;
}
