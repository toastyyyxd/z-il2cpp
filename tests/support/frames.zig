const std = @import("std");
const zil2cpp = @import("z_il2cpp");
const Hooks = zil2cpp.Hooks;
const Runtime = zil2cpp.Runtime;

pub const limit = 8;

var calls: u32 = 0;
var installed: u32 = 0;
var skip_original = false;
var slot_counts: [limit]u32 = @splat(0);

fn Slot(comptime index: usize) type {
    return struct {
        var handle: Hooks.Slot(fn (?*anyopaque) callconv(.c) void) = .{};
        fn detour(instance: ?*anyopaque) callconv(.c) void {
            calls +%= 1;
            slot_counts[index] +%= 1;
            if (skip_original) return;
            handle.original()(instance);
        }
    };
}

const detours = blk: {
    var result: [limit]*const fn (?*anyopaque) callconv(.c) void = undefined;
    for (0..limit) |index| result[index] = &Slot(index).detour;
    break :blk result;
};

fn installSlot(slot: usize, address: ?*anyopaque) bool {
    if (address == null) return false;
    var installed_here = false;
    inline for (0..limit) |index| {
        if (slot == index) {
            Slot(index).handle.install(address.?, &Slot(index).detour, null) catch return false;
            installed_here = true;
        }
    }
    return installed_here;
}

pub fn install(runtime: Runtime, max: u32) u32 {
    const image = runtime.findImage("Assembly-CSharp.dll") catch return 0;
    const effective = @min(limit, max);
    const class_count = image.classCount();
    var index: usize = 0;
    while (index < class_count and installed < effective) : (index += 1) {
        const klass = image.classAt(index) catch continue;
        if (!klass.derivesFromName("MonoBehaviour")) continue;
        if (klass.isGeneric() or klass.isInflated()) continue;
        const method = klass.findMethod("Update", 0) catch continue;
        if (method.isStatic() or method.isGeneric() or method.isInflated()) continue;
        const address = (method.entryPoint() catch continue) orelse continue;
        if (installSlot(installed, address)) installed += 1;
    }
    return installed;
}

pub fn count() u32 {
    return calls;
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
    calls = 0;
    slot_counts = @splat(0);
}

pub fn remove() void {
    inline for (0..limit) |index| {
        Slot(index).handle.detach();
    }
    installed = 0;
}
