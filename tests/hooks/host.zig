const std = @import("std");
const Io = std.Io;

const MH_OK: c_int = 0;

extern fn MH_Initialize() callconv(.winapi) c_int;
extern fn MH_Uninitialize() callconv(.winapi) c_int;
extern fn MH_CreateHook(target: ?*anyopaque, detour: ?*anyopaque, original: ?*?*anyopaque) callconv(.winapi) c_int;
extern fn MH_EnableHook(target: ?*anyopaque) callconv(.winapi) c_int;
extern fn MH_DisableHook(target: ?*anyopaque) callconv(.winapi) c_int;

var calls: u32 = 0;
var original: ?*const fn (i32, i32) callconv(.c) i32 = null;

export fn hooked_target(a: i32, b: i32) callconv(.c) i32 {
    return a +% b;
}

fn detour(a: i32, b: i32) callconv(.c) i32 {
    calls +%= 1;
    const function = original orelse return -1;
    return function(a, b);
}

var target_address: *const fn (i32, i32) callconv(.c) i32 = &hooked_target;

fn callTarget(a: i32, b: i32) i32 {
    const pointer = @as(*volatile *const fn (i32, i32) callconv(.c) i32, @ptrCast(&target_address)).*;
    return pointer(a, b);
}
const target_pointer: *anyopaque = @ptrCast(@constCast(&hooked_target));

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var ok = false;
    var detail: []const u8 = "";
    var first_value: i32 = -999;
    var second_value: i32 = -999;
    var after_enable_value: u32 = 0;

    var status = MH_Initialize();
    if (status != MH_OK) {
        detail = "initialize";
    } else {
        status = MH_CreateHook(target_pointer, @ptrCast(@constCast(&detour)), @ptrCast(&original));
        if (status != MH_OK) {
            detail = "create";
        } else {
            status = MH_EnableHook(target_pointer);
            if (status != MH_OK) {
                detail = "enable";
            } else {
                first_value = callTarget(2, 3);
                after_enable_value = calls;
                _ = MH_DisableHook(target_pointer);
                second_value = callTarget(4, 5);
                ok = first_value == 5 and second_value == 9 and after_enable_value == 1 and calls == 1;
                if (!ok) detail = "behaviour";
            }
        }
        _ = MH_Uninitialize();
    }

    var buffer: [512]u8 = undefined;
    const json = try std.fmt.bufPrint(&buffer, "{{\"ok\": {s}, \"detail\": \"{s}\", \"first\": {d}, \"second\": {d}, \"calls\": {d}, \"after_enable\": {d}}}\n", .{
        if (ok) "true" else "false",
        detail,
        first_value,
        second_value,
        calls,
        after_enable_value,
    });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = "hooks-result.json", .data = json });
    std.debug.print("hooks: {s}", .{json});
    if (!ok) std.process.exit(1);
}
