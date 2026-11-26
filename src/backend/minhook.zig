const Error = @import("../error.zig").Error;

const MH_OK: c_int = 0;

extern fn MH_Initialize() callconv(.winapi) c_int;
extern fn MH_Uninitialize() callconv(.winapi) c_int;
extern fn MH_CreateHook(target: ?*anyopaque, detour: ?*anyopaque, original: ?*?*anyopaque) callconv(.winapi) c_int;
extern fn MH_EnableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_DisableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_RemoveHook(target: ?*anyopaque) callconv(.winapi) c_int;

pub const Prepared = struct {
    target: ?*anyopaque,
    original: *const anyopaque,
};

var initialized = false;

pub fn init() Error!void {
    if (initialized) return;
    try check(MH_Initialize());
    initialized = true;
}

pub fn deinit() Error!void {
    return;
}

pub fn prepare(target: ?*anyopaque, detour: ?*anyopaque) Error!Prepared {
    var original: ?*anyopaque = null;
    try check(MH_CreateHook(target, detour, &original));
    return .{
        .target = target,
        .original = @ptrCast(@alignCast(original orelse return error.HookFailed)),
    };
}

pub fn activate(prepared: Prepared) Error!void {
    try check(MH_EnableHook(prepared.target));
}

pub fn cancel(prepared: Prepared) void {
    _ = MH_RemoveHook(prepared.target);
}

pub fn detach(target: ?*anyopaque) void {
    _ = MH_DisableHook(target);
    _ = MH_RemoveHook(target);
}

pub fn supportsMethodPointer() bool {
    return false;
}

pub fn readPointer(_: usize) ?usize {
    return null;
}

pub fn writePointer(_: usize, _: usize) Error!void {
    return error.HookUnsupported;
}

pub fn usesMemoryPatch() bool {
    return false;
}

fn check(status: c_int) Error!void {
    if (status != MH_OK) return error.HookFailed;
}
