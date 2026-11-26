const Error = @import("../error.zig").Error;

pub const Prepared = struct {
    target: ?*anyopaque = null,
    original: *const anyopaque = undefined,
};

pub fn init() Error!void {}
pub fn deinit() Error!void {}

pub fn prepare(_: ?*anyopaque, _: ?*anyopaque) Error!Prepared {
    return error.HookUnsupported;
}

pub fn activate(_: Prepared) Error!void {
    return error.HookUnsupported;
}

pub fn cancel(_: Prepared) void {}

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

pub fn detach(_: ?*anyopaque) void {}
