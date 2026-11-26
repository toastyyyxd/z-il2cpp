const std = @import("std");
const linux = std.os.linux;
const zil2cpp = @import("z_il2cpp");

const Runtime = zil2cpp.Runtime;
const Loader = zil2cpp.Loader;
const Hooks = zil2cpp.Hooks;

const DomainSignature = fn () callconv(.c) ?*anyopaque;

var domain_hook: ?Hooks.Hook(DomainSignature) = null;
var domain_calls: usize = 0;

fn domainDetour() callconv(.c) ?*anyopaque {
    domain_calls += 1;
    return domain_hook.?.original();
}

fn hookTest() void {
    const raw = getProcAddress(il2cpp_handle, "il2cpp_domain_get") orelse {
        logText("hook: missing symbol");
        return;
    };
    const function: *const DomainSignature = @ptrCast(@alignCast(raw));
    const before = function();
    domain_calls = 0;
    var hook = Hooks.Hook(DomainSignature).install(raw, &domainDetour) catch |err| {
        logFmt("hook: install failed {s}", .{@errorName(err)});
        return;
    };
    domain_hook = hook;
    const after = function();
    domain_hook = null;
    hook.detach();
    logFmt("hook: calls={d} before={x} after={x}", .{ domain_calls, @intFromPtr(before), @intFromPtr(after) });
}

const ELF_MAGIC = [4]u8{ 0x7f, 0x45, 0x4c, 0x46 };
const PT_LOAD = 1;
const PT_DYNAMIC = 2;
const DT_NULL = 0;
const DT_HASH = 4;
const DT_STRTAB = 5;
const DT_SYMTAB = 6;
const DT_STRSZ = 10;
const DT_SYMENT = 11;
const DT_GNU_HASH = 0x6ffffef5;
const LOG_INFO: c_int = 4;
const LOG_PATH = "/data/data/com.example.game/zil2cpp-log.txt";

const ElfHeader = extern struct {
    ident: [16]u8,
    type: u16,
    machine: u16,
    version: u32,
    entry: u64,
    phoff: u64,
    shoff: u64,
    flags: u32,
    ehsize: u16,
    phentsize: u16,
    phnum: u16,
    shentsize: u16,
    shnum: u16,
    shstrndx: u16,
};

const ProgramHeader = extern struct {
    type: u32,
    flags: u32,
    offset: u64,
    vaddr: u64,
    paddr: u64,
    filesz: u64,
    memsz: u64,
    p_align: u64,
};

const Dynamic = extern struct {
    tag: i64,
    value: u64,
};

const Symbol = extern struct {
    name: u32,
    info: u8,
    other: u8,
    shndx: u16,
    value: u64,
    size: u64,
};

const LogFn = *const fn (c_int, [*:0]const u8, [*:0]const u8) callconv(.c) c_int;

var scratch: [8192]u8 align(16) = @splat(0);
var maps_storage: [1048576]u8 = undefined;
var started = false;
var log_fn: ?LogFn = null;
var log_fd: linux.fd_t = -1;

fn openLogFile() void {
    if (log_fd >= 0) return;
    const flags: linux.O = @bitCast(@as(u32, 0o1101));
    const fd = linux.openat(linux.AT.FDCWD, LOG_PATH, flags, 0o644);
    if (syscallOk(fd)) log_fd = @intCast(fd);
}

fn syscallOk(result: usize) bool {
    return @as(isize, @bitCast(result)) >= 0;
}

fn writeFd(fd: linux.fd_t, bytes: []const u8) void {
    if (bytes.len == 0) return;
    _ = linux.write(fd, bytes.ptr, bytes.len);
}

fn sleepMilliseconds(milliseconds: u64) void {
    const request = linux.timespec{ .sec = @intCast(milliseconds / 1000), .nsec = @intCast((milliseconds % 1000) * 1000000) };
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
    writeFd(2, text);
    writeFd(2, "\n");
}

fn logFmt(comptime format: []const u8, args: anytype) void {
    var buffer: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, format, args) catch return;
    logText(text);
}

fn readMaps(buffer: []u8) []const u8 {
    const flags: linux.O = @bitCast(@as(u32, 0));
    const fd = linux.openat(linux.AT.FDCWD, "/proc/self/maps", flags, 0);
    if (!syscallOk(fd)) return buffer[0..0];
    defer _ = linux.close(@intCast(fd));
    var used: usize = 0;
    while (used < buffer.len) {
        const count = linux.read(@intCast(fd), buffer.ptr + used, buffer.len - used);
        if (!syscallOk(count) or count == 0) break;
        used += count;
    }
    return buffer[0..used];
}

fn parseHex(text: []const u8, index: *usize) ?u64 {
    var value: u64 = 0;
    var digits: usize = 0;
    while (index.* < text.len) {
        const byte = text[index.*];
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            'A'...'F' => byte - 'A' + 10,
            else => break,
        };
        value = value * 16 + digit;
        index.* += 1;
        digits += 1;
    }
    if (digits == 0) return null;
    return value;
}

fn findLibraryBase(buffer: []u8, library_name: []const u8) ?usize {
    const maps = readMaps(buffer);
    var line_start: usize = 0;
    var index: usize = 0;
    while (index <= maps.len) : (index += 1) {
        const at_end = index == maps.len or maps[index] == '\n';
        if (!at_end) continue;
        const line = maps[line_start..index];
        line_start = index + 1;
        if (std.mem.indexOf(u8, line, library_name) == null) continue;
        var cursor: usize = 0;
        const start_address = parseHex(line, &cursor) orelse continue;
        return @intCast(start_address);
    }
    return null;
}

fn elfSymbol(base: usize, target_name: []const u8) ?*anyopaque {
    const header: *const ElfHeader = @ptrFromInt(base);
    if (!std.mem.eql(u8, header.ident[0..4], &ELF_MAGIC)) return null;
    if (header.ident[4] != 2) return null;
    const phdrs: [*]const ProgramHeader = @ptrFromInt(base + header.phoff);
    var dynamic_address: usize = 0;
    var header_index: usize = 0;
    while (header_index < header.phnum) : (header_index += 1) {
        if (phdrs[header_index].type == PT_DYNAMIC) {
            dynamic_address = base + @as(usize, @intCast(phdrs[header_index].vaddr));
            break;
        }
    }
    if (dynamic_address == 0) return null;

    var string_table: usize = 0;
    var symbol_table: usize = 0;
    var hash_table: usize = 0;
    var gnu_hash_table: usize = 0;
    var string_size: usize = 0;
    var symbol_size: usize = 24;

    const dynamics: [*]const Dynamic = @ptrFromInt(dynamic_address);
    var dynamic_index: usize = 0;
    while (dynamics[dynamic_index].tag != DT_NULL) : (dynamic_index += 1) {
        const value = @as(usize, @intCast(dynamics[dynamic_index].value));
        switch (dynamics[dynamic_index].tag) {
            DT_STRTAB => string_table = base + value,
            DT_SYMTAB => symbol_table = base + value,
            DT_HASH => hash_table = base + value,
            DT_GNU_HASH => gnu_hash_table = base + value,
            DT_STRSZ => string_size = value,
            DT_SYMENT => symbol_size = value,
            else => {},
        }
    }
    if (string_table == 0 or symbol_table == 0) return null;

    var symbol_count: usize = 0;
    if (gnu_hash_table != 0) {
        const hash_words: [*]const u32 = @ptrFromInt(gnu_hash_table);
        const bucket_count = hash_words[0];
        const symbol_offset = hash_words[1];
        const bloom_size = hash_words[2];
        const buckets_address = gnu_hash_table + 16 + bloom_size * @sizeOf(usize);
        const buckets: [*]const u32 = @ptrFromInt(buckets_address);
        const chains: [*]const u32 = @ptrFromInt(buckets_address + bucket_count * @sizeOf(u32));
        var bucket_index: usize = 0;
        while (bucket_index < bucket_count) : (bucket_index += 1) {
            var symbol_index = buckets[bucket_index];
            if (symbol_index == 0) continue;
            while (true) {
                const chain = chains[symbol_index - symbol_offset];
                if (symbol_index > symbol_count) symbol_count = symbol_index + 1;
                symbol_index += 1;
                if ((chain & 1) != 0) break;
            }
        }
    } else if (hash_table != 0) {
        const hash_words: [*]const u32 = @ptrFromInt(hash_table);
        symbol_count = hash_words[1];
    }
    if (symbol_count == 0) return null;

    const symbols: [*]const Symbol = @ptrFromInt(symbol_table);
    const strings: [*]const u8 = @ptrFromInt(string_table);
    var index: usize = 0;
    while (index < symbol_count) : (index += 1) {
        const symbol = &symbols[index];
        if (symbol.name == 0 or symbol.name >= string_size) continue;
        const name_pointer = strings + symbol.name;
        var name_length: usize = 0;
        while (name_pointer[name_length] != 0) name_length += 1;
        if (!std.mem.eql(u8, name_pointer[0..name_length], target_name)) continue;
        if (symbol.shndx == 0) return null;
        return @ptrFromInt(base + @as(usize, @intCast(symbol.value)));
    }
    return null;
}

fn resolveInLibrary(library_name: []const u8, symbol_name: []const u8) ?*anyopaque {
    const base = findLibraryBase(maps_storage[0..], library_name) orelse return null;
    return elfSymbol(base, symbol_name);
}

fn installLog() void {
    if (resolveInLibrary("liblog.so", "__android_log_write")) |function| {
        log_fn = @ptrCast(@alignCast(function));
    }
}

fn waitForLibrary(library_name: []const u8, timeout_milliseconds: u64) ?usize {
    var waited: u64 = 0;
    while (waited < timeout_milliseconds) : (waited += 100) {
        if (findLibraryBase(maps_storage[0..], library_name)) |base| return base;
        sleepMilliseconds(100);
    }
    return null;
}

fn getModuleHandle(_: [*:0]const u16) callconv(.c) ?*anyopaque {
    return il2cpp_handle;
}

fn getProcAddress(_: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?*anyopaque {
    const symbol = dlsym_fn orelse return null;
    return symbol(il2cpp_handle, name);
}

fn runtimeLoader() Loader {
    return .{ .get_module_handle = getModuleHandle, .get_proc_address = getProcAddress };
}

const Dlopen = *const fn ([*:0]const u8, c_int) callconv(.c) ?*anyopaque;
const Dlsym = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
const RTLD_NOW: c_int = 2;

var il2cpp_handle: ?*anyopaque = null;
var dlopen_fn: ?Dlopen = null;
var dlsym_fn: ?Dlsym = null;

const PthreadStart = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const PthreadCreate = *const fn (*usize, ?*const anyopaque, PthreadStart, ?*anyopaque) callconv(.c) c_int;

fn spawnWorker() void {
    const raw = resolveInLibrary("libc.so", "pthread_create") orelse {
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

fn worker() void {
    logText("start");
    _ = waitForLibrary("libil2cpp.so", 30000) orelse {
        logText("libil2cpp not found");
        return;
    };
    logText("libil2cpp loaded");

    const raw_open = resolveInLibrary("libdl.so", "dlopen") orelse resolveInLibrary("libc.so", "dlopen") orelse {
        logText("dlopen missing");
        return;
    };
    const raw_symbol = resolveInLibrary("libdl.so", "dlsym") orelse resolveInLibrary("libc.so", "dlsym") orelse {
        logText("dlsym missing");
        return;
    };
    dlopen_fn = @ptrCast(@alignCast(raw_open));
    dlsym_fn = @ptrCast(@alignCast(raw_symbol));
    sleepMilliseconds(5000);
    il2cpp_handle = dlopen_fn.?("libil2cpp.so", RTLD_NOW) orelse {
        logText("libil2cpp dlopen failed");
        return;
    };
    logFmt("libil2cpp handle={x}", .{@intFromPtr(il2cpp_handle.?)});
    const domain_get_raw = getProcAddress(il2cpp_handle, "il2cpp_domain_get") orelse {
        logText("il2cpp_domain_get missing");
        return;
    };
    const domain_get: *const fn () callconv(.c) ?*anyopaque = @ptrCast(@alignCast(domain_get_raw));
    var waited: u64 = 0;
    while (waited < 10000) : (waited += 100) {
        if (domain_get() != null) break;
        sleepMilliseconds(100);
    }
    if (domain_get() == null) {
        logText("domain not ready");
        return;
    }
    logText("domain ready");

    const runtime = Runtime.init(runtimeLoader(), scratch[0..]) catch |err| {
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
    hookTest();
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
    _ = &init_array;
    start();
}
