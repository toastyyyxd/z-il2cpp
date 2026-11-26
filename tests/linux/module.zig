const std = @import("std");
const linux = std.os.linux;
const zil2cpp = @import("z_il2cpp");
const frames = @import("frames");

const Runtime = zil2cpp.Runtime;
const Hooks = zil2cpp.Hooks;

const LOG_PATH = "/tmp/zil2cpp-linux.log";

const DomainSignature = fn () callconv(.c) ?*anyopaque;
const WidthSignature = fn (?*anyopaque) callconv(.c) i32;

var log_fd: linux.fd_t = -1;
var scratch: [8192]u8 align(16) = @splat(0);
var started = false;
var domain_hook: ?Hooks.Hook(DomainSignature) = null;
var domain_calls: usize = 0;
var width_hook: ?Hooks.MethodPointerHook(WidthSignature) = null;
var width_calls: usize = 0;
var width_code_hook: ?Hooks.Hook(WidthSignature) = null;
var width_code_calls: usize = 0;

fn openLog() void {
    const flags: linux.O = @bitCast(@as(u32, 0o1101));
    const fd = linux.openat(linux.AT.FDCWD, LOG_PATH, flags, 0o644);
    if (@as(isize, @bitCast(fd)) >= 0) log_fd = @intCast(fd);
}

fn logText(text: []const u8) void {
    if (log_fd < 0) return;
    _ = linux.write(log_fd, text.ptr, text.len);
}

fn logFmt(comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    logText(text);
}

fn sleepMilliseconds(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * 1000000),
    };
    _ = linux.nanosleep(&request, null);
}

fn domainDetour() callconv(.c) ?*anyopaque {
    domain_calls += 1;
    return domain_hook.?.original();
}

fn widthDetour(method: ?*anyopaque) callconv(.c) i32 {
    width_calls += 1;
    return width_hook.?.original(method);
}

fn widthCodeDetour(method: ?*anyopaque) callconv(.c) i32 {
    width_code_calls += 1;
    return width_code_hook.?.original(method);
}

fn hookTests(screen: zil2cpp.Class) void {
    if (zil2cpp.linux.symbol("il2cpp_domain_get")) |raw| {
        const function: *const DomainSignature = @ptrCast(@alignCast(raw));
        _ = function();
        domain_calls = 0;
        if (Hooks.Hook(DomainSignature).install(raw, &domainDetour)) |hook_value| {
            var hook = hook_value;
            domain_hook = hook;
            _ = function();
            domain_hook = null;
            hook.detach();
            _ = function();
            logFmt("code hook calls={d}\n", .{domain_calls});
        } else |err| {
            logFmt("code hook failed: {s}\n", .{@errorName(err)});
        }
    } else logText("code hook: symbol missing\n");

    const method = screen.findMethod("get_width", 0) catch |err| {
        logFmt("width hook find failed: {s}\n", .{@errorName(err)});
        return;
    };
    const before = method.invoke(.{}, i32) catch -1;
    width_calls = 0;
    if (Hooks.MethodPointerHook(WidthSignature).install(method, &widthDetour)) |hook_value| {
        var hook = hook_value;
        width_hook = hook;
        const after = method.invoke(.{}, i32) catch -1;
        width_hook = null;
        hook.detach();
        logFmt("method hook calls={d} before={d} after={d}\n", .{ width_calls, before, after });
    } else |err| {
        logFmt("method hook failed: {s}\n", .{@errorName(err)});
    }

    const entry_address = (method.entryPoint() catch return) orelse return;
    width_code_calls = 0;
    if (Hooks.Hook(WidthSignature).install(entry_address, &widthCodeDetour)) |hook_value| {
        var hook = hook_value;
        width_code_hook = hook;
        const coded = method.invoke(.{}, i32) catch -1;
        width_code_hook = null;
        hook.detach();
        const after_detach = method.invoke(.{}, i32) catch -1;
        logFmt("method code hook calls={d} value={d} after={d}\n", .{ width_code_calls, coded, after_detach });
    } else |err| {
        logFmt("method code hook failed: {s}\n", .{@errorName(err)});
    }
}

fn frameTest(runtime: Runtime) void {
    const installed = frames.install(runtime, frames.max_slots);
    sleepMilliseconds(12000);
    logFmt("frames installed={d} failures={d} calls={d}\n", .{ installed, frames.failureCount(), frames.count() });
    frames.remove();
}

fn worker() void {
    logText("start\n");
    _ = zil2cpp.linux.waitForLibrary("GameAssembly.so", 30000) orelse {
        logText("GameAssembly.so not found\n");
        return;
    };
    logText("GameAssembly.so loaded\n");
    sleepMilliseconds(15000);

    logText("calling loader\n");
    const loader = zil2cpp.linux.loader("GameAssembly.so") catch |err| {
        logFmt("loader failed: {s}\n", .{@errorName(err)});
        return;
    };
    logText("handle ready\n");

    const runtime = Runtime.init(loader, scratch[0..]) catch |err| {
        logFmt("runtime init failed: {s}\n", .{@errorName(err)});
        return;
    };
    const screen = runtime.findClass("UnityEngine", "Screen") catch |err| {
        logFmt("findClass failed: {s}\n", .{@errorName(err)});
        return;
    };
    const method = screen.findMethod("get_width", 0) catch |err| {
        logFmt("findMethod failed: {s}\n", .{@errorName(err)});
        return;
    };
    const width = method.invoke(.{}, i32) catch |err| {
        logFmt("invoke failed: {s}\n", .{@errorName(err)});
        return;
    };
    Hooks.setCodeCaves(true, 0x9e3779b97f4a7c15);
    logFmt("width={d}\n", .{width});
    hookTests(screen);
    frameTest(runtime);
    logText("done\n");
}

fn start() callconv(.c) void {
    if (started) return;
    started = true;
    openLog();
    logText("ctor\n");
    const thread = std.Thread.spawn(.{}, worker, .{}) catch {
        logText("thread failed\n");
        return;
    };
    thread.detach();
}

const init_array: [1]*const fn () callconv(.c) void linksection(".init_array") = .{&start};
comptime {
    @export(&init_array, .{ .name = "zil2cpp_linux_init_array" });
}

export fn zil2cpp_linux_start() callconv(.c) void {
    start();
}
