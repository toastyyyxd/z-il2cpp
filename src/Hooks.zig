const Method = @import("Method.zig").Method;
const Error = @import("error.zig").Error;
const platform = @import("platform.zig");
const Backend = @import("backend/minhook.zig");

pub fn init() Error!void {
    try Backend.init();
}

pub fn deinit() Error!void {
    try Backend.deinit();
}

pub fn Hook(comptime Signature: type) type {
    return struct {
        target: ?*anyopaque,
        original: *const Signature,
        active: bool,
        context: ?*anyopaque,

        pub fn install(target: ?*anyopaque, detour: *const Signature) Error!@This() {
            const original = try Backend.attach(target, @ptrCast(@constCast(detour)));
            return .{
                .target = target,
                .original = @ptrCast(@alignCast(original)),
                .active = true,
                .context = null,
            };
        }

        pub fn installWithContext(target: ?*anyopaque, detour: *const Signature, context: ?*anyopaque) Error!@This() {
            var hook = try install(target, detour);
            hook.context = context;
            return hook;
        }

        pub fn detach(self: *@This()) void {
            if (!self.active) return;
            Backend.detach(self.target);
            self.active = false;
        }
    };
}

pub fn Slot(comptime Signature: type) type {
    return struct {
        hook: ?Hook(Signature) = null,
        context: ?*anyopaque = null,

        pub fn install(self: *@This(), target: ?*anyopaque, detour: *const Signature, context: ?*anyopaque) Error!void {
            self.hook = try Hook(Signature).installWithContext(target, detour, context);
            self.context = context;
        }

        pub fn installMethod(self: *@This(), method: Method, detour: *const Signature, context: ?*anyopaque) Error!void {
            const address = (try method.entryPoint()) orelse return error.MethodNotFound;
            try self.install(address, detour, context);
        }

        pub fn detach(self: *@This()) void {
            if (self.hook) |*hook| hook.detach();
            self.hook = null;
        }

        pub fn original(self: *@This()) *const Signature {
            return self.hook.?.original;
        }

        pub fn active(self: *const @This()) bool {
            return self.hook != null;
        }
    };
}

pub fn hookMethod(comptime Signature: type, method: Method, detour: *const Signature) Error!Hook(Signature) {
    const address = (try method.entryPoint()) orelse return error.MethodNotFound;
    return Hook(Signature).install(address, detour);
}

pub fn hookVirtualMethod(comptime Signature: type, method: Method, instance: ?*anyopaque, detour: *const Signature) Error!Hook(Signature) {
    const resolved = try method.resolveVirtual(instance);
    return hookMethod(Signature, resolved, detour);
}

pub const entry_offset = platform.method_entry_offset;
