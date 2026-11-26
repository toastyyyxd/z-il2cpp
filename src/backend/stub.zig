const Error = @import("../error.zig").Error;

pub fn init() Error!void {}
pub fn deinit() Error!void {}

pub fn attach(_: ?*anyopaque, _: ?*anyopaque) Error!*const anyopaque {
    return error.HookUnsupported;
}

pub fn detach(_: ?*anyopaque) void {}
