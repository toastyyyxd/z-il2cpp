const builtin = @import("builtin");
const Method = @import("Method.zig").Method;
const Error = @import("error.zig").Error;
const platform = @import("platform.zig");
const Backend = if (builtin.os.tag == .windows and builtin.cpu.arch == .x86_64)
    @import("backend/minhook.zig")
else if (builtin.cpu.arch == .aarch64 and builtin.os.tag == .linux)
    @import("backend/arm64.zig")
else if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .linux)
    @import("backend/x86_64_linux.zig")
else
    @import("backend/stub.zig");

pub fn init() Error!void {
    try Backend.init();
}

pub fn supportsMethodPointerHooks() bool {
    return Backend.supportsMethodPointer();
}

pub fn usesMemoryPatch() bool {
    return Backend.usesMemoryPatch();
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
        prepared: Backend.Prepared,

        pub fn prepare(target: ?*anyopaque, detour: *const Signature) Error!@This() {
            const prepared = try Backend.prepare(target, @ptrCast(@constCast(detour)));
            return .{
                .target = target,
                .original = @ptrCast(@alignCast(prepared.original)),
                .active = false,
                .context = null,
                .prepared = prepared,
            };
        }

        pub fn activate(self: *@This()) Error!void {
            if (self.active) return;
            try Backend.activate(self.prepared);
            self.active = true;
        }

        pub fn cancel(self: *@This()) void {
            if (self.active) return;
            Backend.cancel(self.prepared);
        }

        pub fn install(target: ?*anyopaque, detour: *const Signature) Error!@This() {
            var hook = try prepare(target, detour);
            errdefer hook.cancel();
            try hook.activate();
            return hook;
        }

        pub fn installWithContext(target: ?*anyopaque, detour: *const Signature, context: ?*anyopaque) Error!@This() {
            var hook = try prepare(target, detour);
            hook.context = context;
            errdefer hook.cancel();
            try hook.activate();
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
            var hook = try Hook(Signature).prepare(target, detour);
            hook.context = context;
            self.hook = hook;
            self.context = context;
            self.hook.?.activate() catch |err| {
                self.hook.?.cancel();
                self.hook = null;
                return err;
            };
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

pub fn MethodPointerHook(comptime Signature: type) type {
    return struct {
        method: Method,
        address: usize,
        original: *const Signature,
        active: bool,

        pub fn prepare(method: Method, detour: *const Signature) Error!@This() {
            _ = detour;
            if (!supportsMethodPointerHooks()) return error.HookUnsupported;
            const info = @intFromPtr(method.pointer orelse return error.MethodNotFound);
            const address = info + platform.method_entry_offset;
            const original = Backend.readPointer(address) orelse return error.HookFailed;
            return .{
                .method = method,
                .address = address,
                .original = @ptrFromInt(original),
                .active = false,
            };
        }

        pub fn install(method: Method, detour: *const Signature) Error!@This() {
            var hook = try prepare(method, detour);
            try hook.activate(detour);
            return hook;
        }

        pub fn activate(self: *@This(), detour: *const Signature) Error!void {
            if (self.active) return;
            try Backend.writePointer(self.address, @intFromPtr(detour));
            self.active = true;
        }

        pub fn detach(self: *@This()) void {
            if (!self.active) return;
            Backend.writePointer(self.address, @intFromPtr(self.original)) catch {};
            self.active = false;
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
