const std = @import("std");
const linux = std.os.linux;
const Error = @import("../error.zig").Error;
const arm64 = @import("../arm64.zig");

const page_size: usize = 4096;
const max_hooks = 1024;
const near_limit: usize = 124 * 1024 * 1024;
const stub_offset: usize = 0;
const trampoline_offset: usize = 0x100;

const Entry = struct {
    target: usize = 0,
    patch_address: usize = 0,
    stub_page: usize = 0,
    original_instruction: u32 = 0,
    patch_instruction: u32 = 0,
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

pub fn prepare(target_pointer: ?*anyopaque, detour_pointer: ?*anyopaque) Error!Prepared {
    const target = @intFromPtr(target_pointer orelse return error.HookFailed);
    const detour = @intFromPtr(detour_pointer orelse return error.HookFailed);
    const slot = freeSlot() orelse return error.HookFailed;

    const first = readInstruction(target);
    const patch_offset: usize = if (arm64.classify(first) == .bti) 4 else 0;
    const patch_address = target + patch_offset;
    const instruction = readInstruction(patch_address);
    const kind = arm64.classify(instruction);
    const supported = arm64.isCopyable(kind) or kind == .branch_b or kind == .branch_bl;
    if (!supported) return error.HookUnsupported;

    const stub_page = allocateNear(target) orelse return error.HookNoMemory;
    errdefer _ = linux.munmap(@ptrFromInt(stub_page), page_size);

    const trampoline = stub_page + trampoline_offset;
    try buildTrampoline(trampoline, patch_address, instruction, kind);
    var destination = detour;
    if (arm64.encodeBranch(patch_address, destination) == null) {
        buildStub(stub_page + stub_offset, detour);
        destination = stub_page + stub_offset;
    }
    const patch_instruction = arm64.encodeBranch(patch_address, destination) orelse return error.HookUnsupported;

    flushCache(stub_page, stub_page + page_size);
    if (!protect(stub_page, page_size, .{ .READ = true, .EXEC = true })) return error.HookProtectFailed;

    entries[slot] = .{
        .target = target,
        .patch_address = patch_address,
        .stub_page = stub_page,
        .original_instruction = instruction,
        .patch_instruction = patch_instruction,
        .active = false,
    };
    return .{ .slot = slot, .original = @ptrFromInt(trampoline) };
}

pub fn activate(prepared: Prepared) Error!void {
    const entry = &entries[prepared.slot];
    if (entry.active) return;
    writeInstruction(entry.patch_address, entry.patch_instruction) catch return error.HookWriteFailed;
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
            writeInstruction(entry.patch_address, entry.original_instruction) catch {};
        }
        entry.* = .{};
        return;
    }
}

fn freeSlot() ?usize {
    for (&entries, 0..) |*entry, index| {
        if (entry.target == 0) return index;
    }
    return null;
}

fn readInstruction(address: usize) u32 {
    return @as(*const volatile u32, @ptrFromInt(address)).*;
}

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

fn memoryPatchAvailable() bool {
    if (memory_fd == -2) {
        const flags: linux.O = @bitCast(@as(u32, 0o2));
        const fd = linux.openat(linux.AT.FDCWD, "/proc/self/mem", flags, 0);
        memory_fd = if (@as(isize, @bitCast(fd)) >= 0) @intCast(fd) else -1;
    }
    return memory_fd >= 0;
}

fn writeInstruction(address: usize, instruction: u32) !void {
    if (memoryPatchAvailable()) {
        var instruction_copy = instruction;
        const written = linux.pwrite(memory_fd, @ptrCast(&instruction_copy), 4, @intCast(address));
        if (@as(isize, @bitCast(written)) == 4) {
            flushCache(address, address + 4);
            return;
        }
    }
    const page = address & ~(page_size - 1);
    if (!protect(page, page_size, .{ .READ = true, .WRITE = true, .EXEC = true })) {
        return error.HookProtectFailed;
    }
    @as(*volatile u32, @ptrFromInt(address)).* = instruction;
    flushCache(address, address + 4);
    if (!protect(page, page_size, .{ .READ = true, .EXEC = true })) return error.HookFailed;
}

fn protect(address: usize, length: usize, protection: linux.PROT) bool {
    const result = linux.mprotect(@ptrFromInt(address), length, protection);
    return @as(isize, @bitCast(result)) >= 0;
}

fn buildTrampoline(trampoline: usize, patch_address: usize, instruction: u32, kind: arm64.Kind) Error!void {
    switch (kind) {
        .plain, .bti => {
            writeWord(trampoline, instruction);
            const branch = arm64.encodeBranch(trampoline + 4, patch_address + 4) orelse return error.HookUnsupported;
            writeWord(trampoline + 4, branch);
        },
        .branch_b => {
            const destination = arm64.branchDestination(instruction, patch_address);
            writeWord(trampoline, 0x58000050);
            writeWord(trampoline + 4, 0xD61F0200);
            writeQuad(trampoline + 8, destination);
        },
        .branch_bl => {
            const destination = arm64.branchDestination(instruction, patch_address);
            writeWord(trampoline, 0x58000090);
            writeWord(trampoline + 4, 0xD63F0200);
            const branch = arm64.encodeBranch(trampoline + 8, patch_address + 4) orelse return error.HookUnsupported;
            writeWord(trampoline + 8, branch);
            writeWord(trampoline + 12, 0xD503201F);
            writeQuad(trampoline + 16, destination);
        },
        else => return error.HookUnsupported,
    }
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

fn allocateNear(target: usize) ?usize {
    const granularities = [_]usize{ 0x10000, 0x100000 };
    for (granularities) |granularity| {
        var attempt: usize = 0;
        while (attempt < 256) : (attempt += 1) {
            const distance = granularity * (attempt / 2 + 1);
            const candidate = if (attempt % 2 == 0) target -% distance else target + distance;
            const hint = candidate & ~(page_size - 1);
            const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
            const result = linux.mmap(@ptrFromInt(hint), page_size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
            if (@as(isize, @bitCast(result)) < 0) continue;
            const address = result;
            const offset = if (address > target) address - target else target - address;
            if (offset < near_limit) return address;
            _ = linux.munmap(@ptrFromInt(address), page_size);
            break;
        }
    }
    var attempt: usize = 0;
    while (attempt < 2048) : (attempt += 1) {
        const distance = (@as(usize, 1) << 20) * (attempt / 2 + 1);
        const candidate = if (attempt % 2 == 0) target -% distance else target + distance;
        const hint = candidate & ~(page_size - 1);
        const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .FIXED_NOREPLACE = true };
        const result = linux.mmap(@ptrFromInt(hint), page_size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
        if (@as(isize, @bitCast(result)) < 0) continue;
        return result;
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

pub fn configure(_: bool, _: u64) void {}
