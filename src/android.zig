const std = @import("std");
const linux = std.os.linux;
const Error = @import("error.zig").Error;
const Loader = @import("Loader.zig").Loader;
const Elf = @import("Elf.zig");

const RTLD_NOW: c_int = 2;
const maps_size: usize = 1024 * 1024;

var maps_storage: [maps_size]u8 = undefined;
var module_handle: ?*anyopaque = null;
var dlopen_function: ?Dlopen = null;
var dlsym_function: ?Dlsym = null;

const Dlopen = *const fn ([*:0]const u8, c_int) callconv(.c) ?*anyopaque;
const Dlsym = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;

pub fn findLibrary(name: []const u8) ?usize {
    return Elf.findLibraryBase(readMaps(), name);
}

pub fn waitForLibrary(name: []const u8, timeout_milliseconds: u64) ?usize {
    var waited: u64 = 0;
    while (waited < timeout_milliseconds) : (waited += 100) {
        if (Elf.findLibraryBase(readMaps(), name)) |base| return base;
        sleepMilliseconds(100);
    }
    return null;
}

pub fn resolveSymbol(library_name: []const u8, symbol_name: []const u8) ?*anyopaque {
    const base = Elf.findLibraryBase(readMaps(), library_name) orelse return null;
    return Elf.findSymbol(base, symbol_name);
}

pub fn symbol(name: [:0]const u8) ?*anyopaque {
    const lookup = dlsym_function orelse return null;
    return lookup(module_handle, name);
}

pub fn loader(module_name: [:0]const u8) Error!Loader {
    const open = resolveSymbol("libdl.so", "dlopen") orelse
        resolveSymbol("libc.so", "dlopen") orelse return error.MissingExport;
    const lookup = resolveSymbol("libdl.so", "dlsym") orelse
        resolveSymbol("libc.so", "dlsym") orelse return error.MissingExport;
    dlopen_function = @ptrCast(@alignCast(open));
    dlsym_function = @ptrCast(@alignCast(lookup));
    module_handle = dlopen_function.?(module_name, RTLD_NOW) orelse return error.ModuleNotFound;
    return .{
        .get_module_handle = getModuleHandle,
        .get_proc_address = getProcAddress,
    };
}

fn getModuleHandle(_: [*:0]const u16) callconv(.c) ?*anyopaque {
    return module_handle;
}

fn getProcAddress(_: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    const lookup = dlsym_function orelse return null;
    return lookup(module_handle, name);
}

fn readMaps() []const u8 {
    const flags: linux.O = @bitCast(@as(u32, 0));
    const fd = linux.openat(linux.AT.FDCWD, "/proc/self/maps", flags, 0);
    if (!syscallOk(fd)) return maps_storage[0..0];
    defer _ = linux.close(@intCast(fd));
    var used: usize = 0;
    while (used < maps_storage.len) {
        const count = linux.read(@intCast(fd), maps_storage[maps_size * 0 + used ..].ptr, maps_storage.len - used);
        if (!syscallOk(count) or count == 0) break;
        used += count;
    }
    return maps_storage[0..used];
}

fn sleepMilliseconds(milliseconds: u64) void {
    const request = linux.timespec{
        .sec = @intCast(milliseconds / 1000),
        .nsec = @intCast((milliseconds % 1000) * 1000000),
    };
    _ = linux.nanosleep(&request, null);
}

fn syscallOk(result: usize) bool {
    return @as(isize, @bitCast(result)) >= 0;
}
