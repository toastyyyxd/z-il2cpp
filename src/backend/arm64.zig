const std = @import("std");
const linux = std.os.linux;
const Error = @import("../error.zig").Error;

const page_size: usize = 4096;
const max_hooks = 64;
const near_limit: usize = 120 * 1024 * 1024;
const stub_offset: usize = 0;
const trampoline_offset: usize = 0x100;
const literal_offset: usize = 0x180;

const Entry = struct {
    target: usize = 0,
    stub_page: usize = 0,
    original_instruction: u32 = 0,
    active: bool = false,
};

var entries: [max_hooks]Entry = @splat(.{});

pub fn init() Error!void {}
pub fn deinit() Error!void {}

pub fn attach(target_pointer: ?*anyopaque, detour_pointer: ?*anyopaque) Error!*const anyopaque {
    const target = @intFromPtr(target_pointer orelse return error.HookFailed);
    const detour = @intFromPtr(detour_pointer orelse return error.HookFailed);
    const slot = freeSlot() orelse return error.HookFailed;
    const original_instruction = readInstruction(target);

    const stub_page = allocateNear(target) orelse return error.HookNoMemory;
    errdefer _ = linux.munmap(@ptrFromInt(stub_page), page_size);

    const trampoline = stub_page + trampoline_offset;
    buildTrampoline(trampoline, target, original_instruction);
    var patch_address = detour;
    if (!fitsBranch(target, detour)) {
        buildStub(stub_page + stub_offset, detour);
        patch_address = stub_page + stub_offset;
    }
    if (!fitsBranch(target, patch_address)) return error.HookUnsupported;
    if (!protect(stub_page, page_size, .{ .READ = true, .EXEC = true })) return error.HookProtectFailed;

    writeInstruction(target, encodeBranch(target, patch_address)) catch return error.HookWriteFailed;
    entries[slot] = .{
        .target = target,
        .stub_page = stub_page,
        .original_instruction = original_instruction,
        .active = true,
    };
    return @ptrFromInt(trampoline);
}

pub fn detach(target_pointer: ?*anyopaque) void {
    const target = @intFromPtr(target_pointer orelse return);
    for (&entries) |*entry| {
        if (!entry.active or entry.target != target) continue;
        writeInstruction(target, entry.original_instruction) catch {};
        _ = linux.munmap(@ptrFromInt(entry.stub_page), page_size);
        entry.* = .{};
        return;
    }
}

fn freeSlot() ?usize {
    for (&entries, 0..) |*entry, index| {
        if (!entry.active) return index;
    }
    return null;
}

fn readInstruction(address: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(address)).*;
}

fn writeInstruction(address: usize, instruction: u32) !void {
    const page = address & ~(page_size - 1);
    var restored_exec = true;
    if (!protect(page, page_size, .{ .READ = true, .WRITE = true, .EXEC = true })) {
        restored_exec = false;
        if (!protect(page, page_size, .{ .READ = true, .WRITE = true })) return error.HookFailed;
    }
    @as(*volatile u32, @ptrFromInt(address)).* = instruction;
    flushCache(address, address + 4);
    const final: linux.PROT = if (restored_exec) .{ .READ = true, .EXEC = true } else .{ .READ = true, .EXEC = true };
    if (!protect(page, page_size, final)) return error.HookFailed;
}

fn protect(address: usize, length: usize, protection: linux.PROT) bool {
    const result = linux.mprotect(@ptrFromInt(address), length, protection);
    return @as(isize, @bitCast(result)) >= 0;
}

fn buildTrampoline(trampoline: usize, target: usize, instruction: u32) void {
    var cursor = trampoline;
    if (isBranch(instruction)) {
        const destination = @as(usize, @intCast(@as(i64, @intCast(target)) + branchOffset(instruction)));
        writeWord(cursor, 0x58000050);
        writeWord(cursor + 4, 0xD61F0200);
        writeQuad(cursor + 8, destination);
        cursor += 16;
    } else {
        writeWord(cursor, instruction);
        cursor += 4;
    }
    writeWord(cursor, encodeBranch(cursor, target + 4));
}

fn buildStub(stub: usize, destination: usize) void {
    writeWord(stub, 0x58000050);
    writeWord(stub + 4, 0xD61F0200);
    writeQuad(stub + 8, destination);
}

fn writeWord(address: usize, value: u32) void {
    @as(*volatile u32, @ptrFromInt(address)).* = value;
}

fn writeQuad(address: usize, value: usize) void {
    @as(*volatile u64, @ptrFromInt(address)).* = @intCast(value);
}

fn encodeBranch(from: usize, to: usize) u32 {
    const delta = @as(i64, @intCast(to)) - @as(i64, @intCast(from));
    const words: i32 = @intCast(@divExact(delta, 4));
    return 0x14000000 | (@as(u32, @bitCast(words)) & 0x03FFFFFF);
}

fn fitsBranch(from: usize, to: usize) bool {
    const delta = @as(i64, @intCast(to)) - @as(i64, @intCast(from));
    const limit = @as(i64, 1) << 27;
    return delta >= -limit * 4 and delta < limit * 4 and @mod(delta, 4) == 0;
}

fn isBranch(instruction: u32) bool {
    return (instruction & 0x7C000000) == 0x14000000;
}

fn branchOffset(instruction: u32) i64 {
    var immediate: i64 = @intCast((instruction >> 0) & 0x03FFFFFF);
    if ((immediate & 0x02000000) != 0) immediate -= 0x04000000;
    return immediate * 4;
}

fn allocateNear(target: usize) ?usize {
    var attempt: usize = 0;
    while (attempt < 512) : (attempt += 1) {
        const distance = (@as(usize, 1) << 20) * (attempt / 2 + 1);
        const candidate = if (attempt % 2 == 0) target -% distance else target + distance;
        const hint = candidate & ~(page_size - 1);
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = true };
        const result = linux.mmap(@ptrFromInt(hint), page_size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
        if (@as(isize, @bitCast(result)) < 0) continue;
        const address = result;
        const offset = if (address > target) address - target else target - address;
        if (offset < near_limit) return address;
        _ = linux.munmap(@ptrFromInt(address), page_size);
    }
    return null;
}

fn flushCache(start: usize, end: usize) void {
    var cache_type: u64 = undefined;
    asm ("mrs %[value], ctr_el0"
        : [value] "=r" (cache_type),
    );
    const line_size: usize = @as(usize, 4) << @intCast((cache_type >> 16) & 0xF);
    var address = start & ~(line_size - 1);
    while (address < end) : (address += line_size) {
        asm volatile ("dc cvau, %[address]"
            :
            : [address] "r" (address),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    address = start & ~(line_size - 1);
    while (address < end) : (address += line_size) {
        asm volatile ("ic ivau, %[address]"
            :
            : [address] "r" (address),
            : .{ .memory = true });
    }
    asm volatile ("dsb ish" ::: .{ .memory = true });
    asm volatile ("isb" ::: .{ .memory = true });
}
