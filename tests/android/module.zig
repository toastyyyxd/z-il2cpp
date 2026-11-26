const std = @import("std");
const linux = std.os.linux;
const zil2cpp = @import("z_il2cpp");
const build_options = @import("build_options");
const frames = @import("frames");

const Runtime = zil2cpp.Runtime;
const Hooks = zil2cpp.Hooks;
const arm64 = zil2cpp.arm64;
const android = zil2cpp.android;

const LOG_INFO: c_int = 4;
const LOG_PATH = build_options.log_path;
const LOG_PATH_Z = build_options.log_path ++ "\x00";

const PthreadStart = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const PthreadCreate = *const fn (*usize, ?*const anyopaque, PthreadStart, ?*anyopaque) callconv(.c) c_int;
const LogFn = *const fn (c_int, [*:0]const u8, [*:0]const u8) callconv(.c) c_int;

var scratch: [8192]u8 align(16) = @splat(0);
var started = false;
var log_fn: ?LogFn = null;
var log_fd: linux.fd_t = -1;

fn syscallOk(result: usize) bool {
    return @as(isize, @bitCast(result)) >= 0;
}

fn openLogFile() void {
    if (log_fd >= 0) return;
    const flags: linux.O = @bitCast(@as(u32, 0o1101));
    const fd = linux.openat(linux.AT.FDCWD, @ptrCast(&LOG_PATH_Z), flags, 0o644);
    if (syscallOk(fd)) log_fd = @intCast(fd);
}

fn sleepMilliseconds(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * 1000000),
    };
    _ = linux.nanosleep(&request, null);
}

fn logText(text: []const u8) void {
    if (log_fd >= 0) {
        _ = linux.write(log_fd, text.ptr, text.len);
        _ = linux.write(log_fd, "\n", 1);
    }
    var buffer: [512]u8 = undefined;
    if (log_fn) |write_log| {
        const copy = std.fmt.bufPrint(&buffer, "{s}", .{text}) catch return;
        if (copy.len + 1 >= buffer.len) return;
        buffer[copy.len] = 0;
        _ = write_log(LOG_INFO, "zil2cpp", @ptrCast(buffer[0..].ptr));
        return;
    }
    var fallback: [512]u8 = undefined;
    const copy = std.fmt.bufPrint(&fallback, "{s}\n", .{text}) catch return;
    _ = linux.write(2, copy.ptr, copy.len);
}

fn logFmt(comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    logText(text);
}

fn installLog() void {
    if (android.resolveSymbol("liblog.so", "__android_log_write")) |function| {
        log_fn = @ptrCast(@alignCast(function));
    }
}

fn spawnWorker() void {
    const raw = android.resolveSymbol("libc.so", "pthread_create") orelse {
        logText("pthread_create missing");
        return;
    };
    const create: PthreadCreate = @ptrCast(@alignCast(raw));
    var thread: usize = 0;
    _ = create(&thread, null, workerStart, null);
}

fn workerStart(_: ?*anyopaque) callconv(.c) ?*anyopaque {
    worker();
    return null;
}

fn prologueCensus(runtime_value: Runtime) void {
    const image = runtime_value.findImage("Assembly-CSharp.dll") catch {
        logText("census: no image");
        return;
    };
    var counts: [10]usize = @splat(0);
    var examples: usize = 0;
    var sampled: usize = 0;
    const class_count = image.classCount();
    var class_index: usize = 0;
    while (class_index < class_count and sampled < 4000) : (class_index += 1) {
        const klass = image.classAt(class_index) catch continue;
        if (klass.isGeneric() or klass.isInflated()) continue;
        var iterator = klass.methods();
        while (iterator.next()) |method| {
            if (sampled >= 4000) break;
            if (method.isGeneric() or method.isInflated()) continue;
            const address = (method.entryPoint() catch continue) orelse continue;
            const word = @as(*const volatile u32, @ptrFromInt(@intFromPtr(address))).*;
            const kind = arm64.classify(word);
            counts[@backingInt(kind)] += 1;
            sampled += 1;
            if (kind != .plain and examples < 8) {
                logFmt("census: word={x} kind={s}", .{ word, @tagName(kind) });
                examples += 1;
            }
        }
    }
    logFmt("census: sampled={d} plain={d} b={d} bl={d} bti={d} bcond={d} cbz={d} tbz={d} ldr={d} adr={d} adrp={d}", .{
        sampled,
        counts[0],
        counts[1],
        counts[2],
        counts[3],
        counts[4],
        counts[5],
        counts[6],
        counts[7],
        counts[8],
        counts[9],
    });
}

fn frameProbe(runtime_value: Runtime) void {
    const image = runtime_value.findImage("Assembly-CSharp.dll") catch {
        logText("frames: no image");
        return;
    };
    const class_count = image.classCount();
    var seen: usize = 0;
    var index: usize = 0;
    while (index < class_count and seen < frames.limit) : (index += 1) {
        const klass = image.classAt(index) catch continue;
        if (!klass.derivesFromName("MonoBehaviour")) continue;
        if (klass.isGeneric() or klass.isInflated()) continue;
        const method = klass.findMethod("Update", 0) catch continue;
        if (method.isStatic() or method.isGeneric() or method.isInflated()) continue;
        const address = (method.entryPoint() catch continue) orelse continue;
        const instruction = @as(*const volatile u32, @ptrFromInt(@intFromPtr(address))).*;
        logFmt("frames: {d} word={x} kind={s}", .{ seen, instruction, @tagName(arm64.classify(instruction)) });
        seen += 1;
    }
    if (android.findLibrary("libzil2cpp.so")) |base| logFmt("maps: zil2cpp={x}", .{base});
    if (android.findLibrary("libil2cpp.so")) |base| logFmt("maps: il2cpp={x}", .{base});

    const installed = frames.install(runtime_value, frames.limit);
    logFmt("frames: installed={d} failures={d}", .{ installed, frames.failureCount() });
    sleepMilliseconds(8000);
    logFmt("frames: calls={d}", .{frames.count()});
    frames.remove();
    logText("frames: removed");
}

fn worker() void {
    logText("start");
    _ = android.waitForLibrary("libil2cpp.so", 30000) orelse {
        logText("libil2cpp not found");
        return;
    };
    logText("libil2cpp loaded");
    sleepMilliseconds(5000);
    const runtime_loader = android.loader("libil2cpp.so") catch |err| {
        logFmt("loader failed: {s}", .{@errorName(err)});
        return;
    };
    logText("loader ready");
    const runtime = Runtime.init(runtime_loader, scratch[0..]) catch |err| {
        logFmt("runtime init failed: {s}", .{@errorName(err)});
        return;
    };
    const screen = runtime.findClass("UnityEngine", "Screen") catch |err| {
        logFmt("findClass failed: {s}", .{@errorName(err)});
        return;
    };
    const method = screen.findMethod("get_width", 0) catch |err| {
        logFmt("findMethod failed: {s}", .{@errorName(err)});
        return;
    };
    const width = method.invoke(.{}, i32) catch |err| {
        logFmt("invoke failed: {s}", .{@errorName(err)});
        return;
    };
    logFmt("width={d}", .{width});
    logFmt("patching: mem={}", .{Hooks.usesMemoryPatch()});
    prologueCensus(runtime);
    frameProbe(runtime);
    logText("done");
}

fn start() callconv(.c) void {
    if (started) return;
    started = true;
    openLogFile();
    logText("ctor");
    installLog();
    spawnWorker();
}

const init_array: [1]*const fn () callconv(.c) void linksection(".init_array") = .{&start};
comptime {
    @export(&init_array, .{ .name = "zil2cpp_init_array" });
}

export fn zil2cpp_android_start() callconv(.c) void {
    start();
}
