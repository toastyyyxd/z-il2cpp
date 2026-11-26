const std = @import("std");
const linux = std.os.linux;
const zil2cpp = @import("z_il2cpp");

const Runtime = zil2cpp.Runtime;
const Loader = zil2cpp.Loader;
const Elf = zil2cpp.Elf;

const LOG_PATH = "/tmp/zil2cpp-linux.log";
const RTLD_NOW: c_int = 2;

extern fn dlopen(filename: [*:0]const u8, flags: c_int) callconv(.c) ?*anyopaque;
extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) callconv(.c) ?*anyopaque;

var log_fd: linux.fd_t = -1;
var module_handle: ?*anyopaque = null;
var scratch: [8192]u8 align(16) = @splat(0);
var started = false;
var maps_storage: [1024 * 1024]u8 = undefined;

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

fn readMaps() []const u8 {
    const flags: linux.O = @bitCast(@as(u32, 0));
    const fd = linux.openat(linux.AT.FDCWD, "/proc/self/maps", flags, 0);
    if (@as(isize, @bitCast(fd)) < 0) return maps_storage[0..0];
    defer _ = linux.close(@intCast(fd));
    var used: usize = 0;
    while (used < maps_storage.len) {
        const count = linux.read(@intCast(fd), maps_storage[used..].ptr, maps_storage.len - used);
        if (@as(isize, @bitCast(count)) <= 0) break;
        used += count;
    }
    return maps_storage[0..used];
}

fn waitForLibrary(name: []const u8, timeout_milliseconds: u64) ?usize {
    var waited: u64 = 0;
    while (waited < timeout_milliseconds) : (waited += 100) {
        if (Elf.findLibraryBase(readMaps(), name)) |base| return base;
        sleepMilliseconds(100);
    }
    return null;
}

fn libraryPath(name: []const u8, buffer: []u8) ?[:0]const u8 {
    const maps = readMaps();
    var line_start: usize = 0;
    var index: usize = 0;
    while (index <= maps.len) : (index += 1) {
        const at_end = index == maps.len or maps[index] == '\n';
        if (!at_end) continue;
        const line = maps[line_start..index];
        line_start = index + 1;
        const position = std.mem.indexOf(u8, line, name) orelse continue;
        var path_start = position;
        while (path_start > 0 and line[path_start - 1] != ' ') path_start -= 1;
        const path = line[path_start..];
        if (path.len == 0 or path[0] != '/') continue;
        if (path.len >= buffer.len) continue;
        @memcpy(buffer[0..path.len], path);
        buffer[path.len] = 0;
        return buffer[0..path.len :0];
    }
    return null;
}

fn getModuleHandle(_: [*:0]const u16) callconv(.c) ?*anyopaque {
    return module_handle;
}

fn getProcAddress(_: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    return dlsym(module_handle, name);
}

fn worker() void {
    logText("start\n");
    _ = waitForLibrary("GameAssembly.so", 30000) orelse {
        logText("GameAssembly.so not found\n");
        return;
    };
    logText("GameAssembly.so loaded\n");
    sleepMilliseconds(5000);

    module_handle = dlopen("GameAssembly.so", RTLD_NOW);
    if (module_handle == null) {
        var path_buffer: [4096]u8 = undefined;
        if (libraryPath("GameAssembly.so", &path_buffer)) |path| {
            module_handle = dlopen(path.ptr, RTLD_NOW);
        }
    }
    if (module_handle == null) {
        logText("dlopen failed\n");
        return;
    }
    logText("handle ready\n");

    const loader = Loader{
        .get_module_handle = getModuleHandle,
        .get_proc_address = getProcAddress,
    };
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
    logFmt("width={d}\n", .{width});
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
