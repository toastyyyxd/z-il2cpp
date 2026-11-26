const Error = @import("error.zig").Error;

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

pub fn TypedHook(comptime Signature: type) type {
    return struct {
        target: ?*anyopaque,
        original: *const Signature,
        active: bool,

        pub fn install(target: ?*anyopaque, detour: *const Signature) Error!@This() {
            var original_raw: ?*anyopaque = null;
            try check(MH_CreateHook(target, @ptrCast(@constCast(detour)), @ptrCast(&original_raw)));
            const original: *const Signature = @ptrCast(@alignCast(original_raw orelse return error.HookFailed));
            try check(MH_EnableHook(target));
            return .{ .target = target, .original = original, .active = true };
        }

        pub fn detach(self: *@This()) void {
            if (!self.active) return;
            _ = MH_DisableHook(self.target);
            _ = MH_RemoveHook(self.target);
            self.active = false;
        }
    };
}

fn check(status: c_int) Error!void {
    if (status != MH_OK) return error.HookFailed;
}
