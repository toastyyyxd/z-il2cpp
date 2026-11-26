const MinHook = @import("MinHook.zig");
const Method = @import("Method.zig").Method;
const Error = @import("error.zig").Error;

pub const Hook = MinHook.TypedHook;

pub fn init() Error!void {
    try MinHook.init();
}

pub fn deinit() Error!void {
    try MinHook.deinit();
}

pub fn hookMethod(comptime Signature: type, method: Method, detour: *const Signature) Error!Hook(Signature) {
    const address = (try method.entryPoint()) orelse return error.MethodNotFound;
    return Hook(Signature).install(address, detour);
}
