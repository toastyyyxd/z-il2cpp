const std = @import("std");
const zil2cpp = @import("z_il2cpp");
const Hooks = zil2cpp.Hooks;
const Runtime = zil2cpp.Runtime;
const Method = zil2cpp.Method;

pub const limit = 8;

const Signature = fn (?*anyopaque, ?*anyopaque) callconv(.c) void;

var calls: u32 = 0;
var installed: u32 = 0;
var skip_original = false;
var failures: u32 = 0;
var slot_counts: [limit]u32 = @splat(0);

fn Slot(comptime index: usize) type {
    return struct {
        var code: Hooks.Slot(Signature) = .{};
        var pointer: ?Hooks.MethodPointerHook(Signature) = null;

        fn detour(instance: ?*anyopaque, method: ?*anyopaque) callconv(.c) void {
            calls +%= 1;
            slot_counts[index] +%= 1;
            if (skip_original) return;
            if (pointer) |*hook| {
                hook.original(instance, method);
            } else {
                code.original()(instance, method);
            }
        }
    };
}

const detours = blk: {
    var result: [limit]*const Signature = undefined;
    for (0..limit) |index| result[index] = &Slot(index).detour;
    break :blk result;
};

fn installSlot(slot: usize, method: Method, address: ?*anyopaque) bool {
    if (address == null) return false;
    inline for (0..limit) |index| {
        if (slot == index) {
            if (Hooks.supportsMethodPointerHooks()) {
                Slot(index).pointer = Hooks.MethodPointerHook(Signature).install(method, &Slot(index).detour) catch {
                    failures += 1;
                    return false;
                };
            } else {
                Slot(index).code.install(address.?, &Slot(index).detour, null) catch {
                    failures += 1;
                    return false;
                };
            }
            return true;
        }
    }
    return false;
}

pub fn install(runtime: Runtime, max: u32) u32 {
    return installRange(runtime, 0, max);
}

pub fn installRange(runtime: Runtime, start_index: u32, max: u32) u32 {
    const image = runtime.findImage("Assembly-CSharp.dll") catch return 0;
    const effective = @min(limit, max);
    const class_count = image.classCount();
    var candidate: u32 = 0;
    var index: usize = 0;
    while (index < class_count and installed < effective) : (index += 1) {
        const klass = image.classAt(index) catch continue;
        if (!klass.derivesFromName("MonoBehaviour")) continue;
        if (klass.isGeneric() or klass.isInflated()) continue;
        const method = klass.findMethod("Update", 0) catch continue;
        if (method.isStatic() or method.isGeneric() or method.isInflated()) continue;
        const address = (method.entryPoint() catch continue) orelse continue;
        if (candidate < start_index) {
            candidate += 1;
            continue;
        }
        if (installSlot(installed, method, address)) installed += 1;
        candidate += 1;
    }
    return installed;
}

pub fn count() u32 {
    return calls;
}

pub fn failureCount() u32 {
    return failures;
}

pub fn installedCount() u32 {
    return installed;
}

pub fn skipOriginal(enable: bool) void {
    skip_original = enable;
}

pub fn slotCount(index: usize) u32 {
    return if (index < limit) slot_counts[index] else 0;
}

pub fn reset() void {
    failures = 0;
    calls = 0;
    slot_counts = @splat(0);
}

pub fn remove() void {
    inline for (0..limit) |index| {
        if (Slot(index).pointer) |*hook| {
            hook.detach();
            Slot(index).pointer = null;
        }
        Slot(index).code.detach();
    }
    installed = 0;
}
