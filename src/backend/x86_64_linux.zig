const std = @import("std");
const linux = std.os.linux;
const Error = @import("../error.zig").Error;

const x86 = @import("../x86_64.zig");

const page_size: usize = 4096;
const patch_size: usize = 5;
const max_hooks = 64;
const near_limit: usize = 1536 * 1024 * 1024;
const stub_offset: usize = 0;
const trampoline_offset: usize = 0x100;

const Entry = struct {
    target: usize = 0,
    patch_address: usize = 0,
    stub_page: usize = 0,
    original_bytes: [8]u8 = @splat(0),
    patch_bytes: [patch_size]u8 = @splat(0),
    active: bool = false,
};

pub const Prepared = struct {
    slot: usize,
    original: *const anyopaque,
};

var entries: [max_hooks]Entry = @splat(.{});
var memory_fd: linux.fd_t = -2;

pub fn init() Error!void {}
pub fn deinit() Error!void {}

pub fn supportsMethodPointer() bool {
    return true;
}

pub fn readPointer(address: usize) ?usize {
    if (!memoryPatchAvailable()) return null;
    var value: u64 = 0;
    const count = linux.pread(memory_fd, @ptrCast(&value), 8, @intCast(address));
    if (@as(isize, @bitCast(count)) != 8) return null;
    return @intCast(value);
}

pub fn writePointer(address: usize, value: usize) Error!void {
    if (!memoryPatchAvailable()) return error.HookProtectFailed;
    var copy: u64 = @intCast(value);
    const count = linux.pwrite(memory_fd, @ptrCast(&copy), 8, @intCast(address));
    if (@as(isize, @bitCast(count)) != 8) return error.HookWriteFailed;
}

pub fn usesMemoryPatch() bool {
    return memoryPatchAvailable();
}

pub fn prepare(target_pointer: ?*anyopaque, detour_pointer: ?*anyopaque) Error!Prepared {
    const target = @intFromPtr(target_pointer orelse return error.HookFailed);
    const detour = @intFromPtr(detour_pointer orelse return error.HookFailed);
    const slot = freeSlot() orelse return error.HookFailed;

    const patch_offset: usize = if (std.mem.eql(u8, slice(target, 4), "\xF3\x0F\x1E\xFA")) 4 else 0;
    const patch_address = target + patch_offset;

    var copied: usize = 0;
    var relative_seen = false;
    var instructions: usize = 0;
    while (copied < patch_size) {
        const code: *const [16]u8 = @ptrCast(slice(patch_address + copied, 16).ptr);
        const decoded = x86.decode(code);
        if (!decoded.ok) return error.HookUnsupported;
        if (decoded.relative) relative_seen = true;
        copied += decoded.length;
        instructions += 1;
        if (instructions > 8) return error.HookUnsupported;
    }
    var absolute_destination: ?usize = null;
    if (relative_seen) {
        if (instructions != 1) return error.HookUnsupported;
        const first = slice(patch_address, 16);
        if (first[0] == 0xE9 and copied == 5) {
            absolute_destination = @intCast(@as(i64, @intCast(patch_address + 5)) + readInt(i32, patch_address + 1));
        } else if (first[0] == 0xEB and copied == 2) {
            absolute_destination = @intCast(@as(i64, @intCast(patch_address + 2)) + @as(i8, @bitCast(first[1])));
        } else {
            return error.HookUnsupported;
        }
    }

    const stub_page = allocateNear(target) orelse return error.HookNoMemory;
    errdefer _ = linux.munmap(@ptrFromInt(stub_page), page_size);

    const trampoline = stub_page + trampoline_offset;
    try buildTrampoline(trampoline, patch_address, copied, target, stub_page, absolute_destination);

    var destination = detour;
    if (!fitsRelative(patch_address + patch_size, detour)) {
        buildStub(stub_page + stub_offset, detour);
        destination = stub_page + stub_offset;
    }
    if (!fitsRelative(patch_address + patch_size, destination)) return error.HookUnsupported;

    var patch: [patch_size]u8 = undefined;
    patch[0] = 0xE9;
    const delta = @as(i64, @intCast(destination)) - @as(i64, @intCast(patch_address + patch_size));
    std.mem.writeInt(i32, patch[1..5], @intCast(delta), .little);

    flushCode(stub_page, stub_page + page_size);
    if (!protect(stub_page, page_size, .{ .READ = true, .EXEC = true })) return error.HookProtectFailed;

    entries[slot] = .{
        .target = target,
        .patch_address = patch_address,
        .stub_page = stub_page,
        .original_bytes = readBytes(patch_address, 8),
        .patch_bytes = patch,
        .active = false,
    };
    return .{ .slot = slot, .original = @ptrFromInt(trampoline) };
}

pub fn activate(prepared: Prepared) Error!void {
    const entry = &entries[prepared.slot];
    if (entry.active) return;
    writeBytes(entry.patch_address, &entry.patch_bytes) catch return error.HookWriteFailed;
    entry.active = true;
}

pub fn cancel(prepared: Prepared) void {
    const entry = &entries[prepared.slot];
    if (entry.active) return;
    _ = linux.munmap(@ptrFromInt(entry.stub_page), page_size);
    entry.* = .{};
}

pub fn detach(target_pointer: ?*anyopaque) void {
    const target = @intFromPtr(target_pointer orelse return);
    for (&entries) |*entry| {
        if (entry.target != target) continue;
        if (entry.active) {
            writeBytes(entry.patch_address, &entry.original_bytes) catch {};
        }
        entry.* = .{};
        return;
    }
}

fn buildTrampoline(trampoline: usize, patch_address: usize, copied: usize, target: usize, stub_page: usize, absolute_destination: ?usize) Error!void {
    if (absolute_destination) |destination| {
        @memcpy(slice(trampoline, 6), &[_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 });
        writeInt(usize, trampoline + 6, destination);
        return;
    }
    var source: usize = 0;
    while (source < copied) {
        const code: *const [16]u8 = @ptrCast(slice(patch_address + source, 16).ptr);
        const decoded = x86.decode(code);
        if (!decoded.ok) return error.HookUnsupported;
        @memcpy(slice(trampoline + source, decoded.length), slice(patch_address + source, decoded.length));
        if (decoded.rip_disp_offset) |offset| {
            const old_disp = readInt(i32, patch_address + source + offset);
            const adjustment = @as(i64, @intCast(target)) - @as(i64, @intCast(stub_page));
            const updated = @as(i64, old_disp) + adjustment;
            if (updated < std.math.minInt(i32) or updated > std.math.maxInt(i32)) return error.HookUnsupported;
            writeInt(i32, trampoline + source + offset, @intCast(updated));
        }
        source += decoded.length;
    }
    var jump: [patch_size]u8 = undefined;
    jump[0] = 0xE9;
    const delta = @as(i64, @intCast(patch_address + copied)) - @as(i64, @intCast(trampoline + copied + patch_size));
    writeInt(i32, trampoline + copied + 1, @intCast(delta));
    jump[1..5].* = slice(trampoline + copied + 1, 4)[0..4].*;
    @memcpy(slice(trampoline + copied, patch_size), &jump);
}

fn buildStub(stub: usize, destination: usize) void {
    @memcpy(slice(stub, 6), &[_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 });
    writeInt(usize, stub + 6, destination);
}

fn readInt(comptime T: type, address: usize) T {
    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), slice(address, @sizeOf(T)));
    return result;
}

fn writeInt(comptime T: type, address: usize, value: T) void {
    @memcpy(slice(address, @sizeOf(T)), std.mem.asBytes(&value));
}

fn fitsRelative(from: usize, to: usize) bool {
    const delta = @as(i64, @intCast(to)) - @as(i64, @intCast(from));
    return delta >= std.math.minInt(i32) and delta <= std.math.maxInt(i32);
}

fn allocateNear(target: usize) ?usize {
    var attempt: usize = 0;
    while (attempt < 192) : (attempt += 1) {
        const distance = (@as(usize, 1) << 20) + attempt * (@as(usize, 1) << 24);
        const candidate = if (attempt % 2 == 0) target -% distance else target +% distance;
        const hint = candidate & ~(page_size - 1);
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        const result = linux.mmap(@ptrFromInt(hint), page_size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
        if (@as(isize, @bitCast(result)) < 0) continue;
        const address = result;
        const offset = if (address > target) address - target else target - address;
        if (offset < near_limit) return address;
        _ = linux.munmap(@ptrFromInt(address), page_size);
    }
    const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
    const address = linux.mmap(null, page_size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
    if (@as(isize, @bitCast(address)) < 0) return null;
    const offset = if (address > target) address - target else target - address;
    if (offset < near_limit) return address;
    _ = linux.munmap(@ptrFromInt(address), page_size);
    return null;
}

fn memoryPatchAvailable() bool {
    if (memory_fd == -2) {
        const flags: linux.O = @bitCast(@as(u32, 0o2));
        const fd = linux.openat(linux.AT.FDCWD, "/proc/self/mem", flags, 0);
        memory_fd = if (@as(isize, @bitCast(fd)) >= 0) @intCast(fd) else -1;
    }
    return memory_fd >= 0;
}

fn writeBytes(address: usize, bytes: []const u8) !void {
    if (memoryPatchAvailable()) {
        const written = linux.pwrite(memory_fd, bytes.ptr, bytes.len, @intCast(address));
        if (@as(isize, @bitCast(written)) == @as(isize, @intCast(bytes.len))) {
            flushCode(address, address + bytes.len);
            return;
        }
    }
    const page = address & ~(page_size - 1);
    if (!protect(page, page_size, .{ .READ = true, .WRITE = true, .EXEC = true })) return error.HookProtectFailed;
    @memcpy(slice(address, bytes.len), bytes);
    flushCode(address, address + bytes.len);
    if (!protect(page, page_size, .{ .READ = true, .EXEC = true })) return error.HookFailed;
}

fn readBytes(address: usize, count: usize) [8]u8 {
    var result: [8]u8 = @splat(0);
    @memcpy(result[0..count], slice(address, count));
    return result;
}

fn flushCode(start: usize, end: usize) void {
    _ = start;
    _ = end;
}

fn protect(address: usize, length: usize, protection: linux.PROT) bool {
    const result = linux.mprotect(@ptrFromInt(address), length, protection);
    return @as(isize, @bitCast(result)) >= 0;
}

fn slice(address: usize, count: usize) []u8 {
    return @as([*]u8, @ptrFromInt(address))[0..count];
}

fn freeSlot() ?usize {
    for (&entries, 0..) |*entry, index| {
        if (entry.target == 0) return index;
    }
    return null;
}
