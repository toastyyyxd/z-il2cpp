const std = @import("std");
const linux = std.os.linux;
const Error = @import("../error.zig").Error;
const x86 = @import("../x86_64.zig");

const page_size: usize = 4096;
const patch_size: usize = 5;
const max_hooks: usize = 4096;
const slot_size: usize = 64;
const slots_per_page: usize = page_size / slot_size;
const max_pages: usize = 64;
const near_limit: usize = 1536 * 1024 * 1024;
const trampoline_offset: usize = 24;
const maps_size: usize = 1024 * 1024;

const SlotKind = enum { unused, pool, cave };

const Entry = struct {
    target: usize = 0,
    patch_address: usize = 0,
    slot_address: usize = 0,
    trampoline_address: usize = 0,
    data_pointer: usize = 0,
    slot_offset: usize = 0,
    page: usize = 0,
    kind: SlotKind = .unused,
    original_bytes: [patch_size]u8 = @splat(0),
    patch_bytes: [patch_size]u8 = @splat(0),
    active: bool = false,
};

const Page = struct {
    address: usize = 0,
    fd: linux.fd_t = -1,
    used: std.atomic.Value(u16) = .init(0),
    refs: std.atomic.Value(u32) = .init(0),
};

pub const Prepared = struct {
    slot: usize,
    original: *const anyopaque,
};

const DataPage = struct {
    address: usize = 0,
    used: std.atomic.Value(u16) = .init(0),
};

var entries: [max_hooks]Entry = @splat(.{});
var pages: [max_pages]Page = @splat(.{});
var data_pages: [max_pages]DataPage = @splat(.{});
var maps_storage: [maps_size]u8 = undefined;

const Cave = struct { start: usize, length: usize };
const max_caves = 2048;
var cave_candidates: [max_caves]Cave = @splat(.{ .start = 0, .length = 0 });
var cave_count: usize = 0;
var caves_scanned = false;
var memory_fd: linux.fd_t = -2;
var caves_enabled = false;
var cave_seed: u64 = 0;

pub fn init() Error!void {}

pub fn deinit() Error!void {
    for (&pages) |*page| {
        if (page.address == 0) continue;
        _ = linux.munmap(@ptrFromInt(page.address), page_size);
        if (page.fd >= 0) _ = linux.close(page.fd);
        page.* = .{};
    }
    for (&data_pages) |*page| {
        if (page.address == 0) continue;
        _ = linux.munmap(@ptrFromInt(page.address), page_size);
        page.* = .{};
    }
}

pub fn configure(code_caves: bool, entropy: u64) void {
    caves_enabled = code_caves;
    cave_seed = entropy;
}

pub fn supportsMethodPointer() bool {
    return true;
}

pub fn usesMemoryPatch() bool {
    return memoryPatchAvailable();
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

pub fn prepare(target_pointer: ?*anyopaque, detour_pointer: ?*anyopaque) Error!Prepared {
    const target = @intFromPtr(target_pointer orelse return error.HookFailed);
    const detour = @intFromPtr(detour_pointer orelse return error.HookFailed);
    const slot = freeSlot() orelse return error.HookFailed;
    entries[slot] = .{};

    const patch_address = target;

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

    const allocation = try acquireSlot(target, patch_address, copied);
    errdefer releaseSlot(allocation);
    const data_pointer = try acquireDataPointer(target);
    @atomicStore(u64, @as(*u64, @ptrFromInt(data_pointer)), detour, .release);

    try writeHookCode(allocation, data_pointer, patch_address, copied, absolute_destination);

    var patch: [patch_size]u8 = undefined;
    patch[0] = 0xE9;
    const delta = @as(i64, @intCast(allocation.address)) - @as(i64, @intCast(patch_address + patch_size));
    if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) return error.HookUnsupported;
    std.mem.writeInt(i32, patch[1..5], @intCast(delta), .little);

    entries[slot] = .{
        .target = target,
        .patch_address = patch_address,
        .slot_address = allocation.address,
        .trampoline_address = allocation.trampoline,
        .data_pointer = data_pointer,
        .slot_offset = allocation.offset,
        .page = allocation.page,
        .kind = allocation.kind,
        .original_bytes = readBytes(patch_address, patch_size),
        .patch_bytes = patch,
        .active = false,
    };
    return .{ .slot = slot, .original = @ptrFromInt(allocation.trampoline) };
}

pub fn activate(prepared: Prepared) Error!void {
    const entry = &entries[prepared.slot];
    if (entry.active) return;
    writeEntryPatch(entry.patch_address, &entry.patch_bytes) catch return error.HookWriteFailed;
    entry.active = true;
}

pub fn cancel(prepared: Prepared) void {
    const entry = &entries[prepared.slot];
    if (entry.active) return;
    releaseSlot(.{
        .address = entry.slot_address,
        .trampoline = entry.trampoline_address,
        .offset = entry.slot_offset,
        .page = entry.page,
        .kind = entry.kind,
    });
    entry.* = .{};
}

pub fn detach(target_pointer: ?*anyopaque) void {
    const target = @intFromPtr(target_pointer orelse return);
    for (&entries) |*entry| {
        if (entry.target != target) continue;
        if (entry.active and entry.data_pointer != 0) {
            @atomicStore(u64, @as(*u64, @ptrFromInt(entry.data_pointer)), entry.trampoline_address, .release);
        }
        releaseSlot(.{
            .address = entry.slot_address,
            .trampoline = entry.trampoline_address,
            .offset = entry.slot_offset,
            .page = entry.page,
            .kind = entry.kind,
        });
        entry.* = .{};
        return;
    }
}

const Allocation = struct {
    address: usize,
    trampoline: usize,
    offset: usize = 0,
    page: usize = 0,
    kind: SlotKind = .unused,
};

fn near(address: usize, target: usize) bool {
    const offset = if (address > target) address - target else target - address;
    return offset < near_limit;
}

fn acquireSlot(target: usize, patch_address: usize, copied: usize) Error!Allocation {
    if (caves_enabled and memoryPatchAvailable()) {
        if (caveAllocation(target, patch_address, copied)) |allocation| return allocation;
    }
    for (&pages, 0..) |*page, index| {
        if (page.address == 0 or !near(page.address, target)) continue;
        const slot_index = page.used.fetchAdd(1, .monotonic);
        if (slot_index >= slots_per_page) {
            _ = page.used.fetchSub(1, .monotonic);
            continue;
        }
        _ = page.refs.fetchAdd(1, .monotonic);
        const slot_address = page.address + @as(usize, slot_index) * slot_size;
        return .{
            .address = slot_address,
            .trampoline = slot_address + trampoline_offset,
            .offset = @as(usize, slot_index) * slot_size,
            .page = index,
            .kind = .pool,
        };
    }
    for (&pages, 0..) |*page, index| {
        if (page.address != 0) continue;
        const created = createPoolPage(target) catch continue;
        page.* = created;
        page.used.store(1, .monotonic);
        _ = page.refs.fetchAdd(1, .monotonic);
        return .{ .address = page.address, .trampoline = page.address + trampoline_offset, .page = index, .kind = .pool };
    }
    return error.HookNoMemory;
}

fn releaseSlot(allocation: Allocation) void {
    if (allocation.kind == .pool and allocation.page < max_pages) {
        _ = pages[allocation.page].refs.fetchSub(1, .monotonic);
    }
}

fn createPoolPage(target: usize) Error!Page {
    const fd = @as(isize, @bitCast(linux.memfd_create("zil2cpp-pool", 0)));
    if (fd < 0) return error.HookNoMemory;
    errdefer _ = linux.close(@intCast(fd));
    if (@as(isize, @bitCast(linux.ftruncate(@intCast(fd), page_size))) < 0) return error.HookNoMemory;

    var attempt: usize = 0;
    while (attempt < 192) : (attempt += 1) {
        const distance = (@as(usize, 1) << 20) + attempt * (@as(usize, 1) << 24);
        const candidate = if (attempt % 2 == 0) target -% distance else target +% distance;
        const hint = candidate & ~(page_size - 1);
        const flags: linux.MAP = .{ .TYPE = .SHARED };
        const result = linux.mmap(@ptrFromInt(hint), page_size, .{ .READ = true, .WRITE = true }, flags, @intCast(fd), 0);
        if (@as(isize, @bitCast(result)) < 0) continue;
        if (!near(result, target)) {
            _ = linux.munmap(@ptrFromInt(result), page_size);
            continue;
        }
        if (@as(isize, @bitCast(linux.mprotect(@ptrFromInt(result), page_size, .{ .READ = true, .EXEC = true }))) < 0) {
            _ = linux.munmap(@ptrFromInt(result), page_size);
            return error.HookProtectFailed;
        }
        return .{ .address = result, .fd = @intCast(fd) };
    }
    return error.HookNoMemory;
}

fn writeHookCode(allocation: Allocation, data_pointer: usize, patch_address: usize, copied: usize, absolute_destination: ?usize) Error!void {
    if (allocation.kind == .cave) {
        var stub: [16]u8 = @splat(0);
        @memcpy(stub[0..6], &[_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 });
        const displacement = @as(i64, @intCast(data_pointer)) - @as(i64, @intCast(allocation.address + 6));
        if (displacement < std.math.minInt(i32) or displacement > std.math.maxInt(i32)) return error.HookUnsupported;
        writeIntToSliceAt(&stub, 2, @as(i32, @intCast(displacement)));
        writeBytes(allocation.address, &stub) catch return error.HookWriteFailed;

        var trampoline: [48]u8 = @splat(0);
        try fillTrampoline(&trampoline, allocation.trampoline, patch_address, copied, absolute_destination);
        var length: usize = copied + patch_size;
        if (absolute_destination != null) length = 14;
        writeBytes(allocation.trampoline, trampoline[0..length]) catch return error.HookWriteFailed;
        return;
    }

    if (allocation.page >= max_pages or pages[allocation.page].fd < 0) return error.HookWriteFailed;
    var image: [slot_size]u8 = @splat(0);
    @memcpy(image[0..6], &[_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 });
    const displacement = @as(i64, @intCast(data_pointer)) - @as(i64, @intCast(allocation.address + 6));
    if (displacement < std.math.minInt(i32) or displacement > std.math.maxInt(i32)) return error.HookUnsupported;
    writeIntToSliceAt(&image, 2, @as(i32, @intCast(displacement)));
    try fillTrampoline(image[trampoline_offset..], allocation.trampoline, patch_address, copied, absolute_destination);
    const written = linux.pwrite(pages[allocation.page].fd, &image, slot_size, @intCast(allocation.offset));
    if (@as(isize, @bitCast(written)) != @as(isize, @intCast(slot_size))) return error.HookWriteFailed;
}

fn fillTrampoline(buffer: []u8, trampoline_address: usize, patch_address: usize, copied: usize, absolute_destination: ?usize) Error!void {
    @memset(buffer[0..@min(buffer.len, 48)], 0);
    if (absolute_destination) |destination| {
        @memcpy(buffer[0..6], &[_]u8{ 0xFF, 0x25, 0x00, 0x00, 0x00, 0x00 });
        writeIntToSlice(buffer, 6, destination);
        return;
    }
    var source: usize = 0;
    while (source < copied) {
        const code: *const [16]u8 = @ptrCast(slice(patch_address + source, 16).ptr);
        const decoded = x86.decode(code);
        if (!decoded.ok) return error.HookUnsupported;
        if (source + decoded.length > buffer.len) return error.HookUnsupported;
        @memcpy(buffer[source..][0..decoded.length], slice(patch_address + source, decoded.length));
        if (decoded.rip_disp_offset) |offset| {
            const old_disp = readInt(i32, patch_address + source + offset);
            const old_ip = patch_address + source;
            const new_ip = trampoline_address + source;
            const adjustment = @as(i64, @intCast(old_ip)) - @as(i64, @intCast(new_ip));
            const updated = @as(i64, old_disp) + adjustment;
            if (updated < std.math.minInt(i32) or updated > std.math.maxInt(i32)) return error.HookUnsupported;
            writeIntToSliceAt(buffer, source + offset, @as(i32, @intCast(updated)));
        }
        source += decoded.length;
    }
    if (copied + patch_size > buffer.len) return error.HookUnsupported;
    const jump_position = copied;
    const delta = @as(i64, @intCast(patch_address + copied)) - @as(i64, @intCast(trampoline_address + jump_position + patch_size));
    if (delta < std.math.minInt(i32) or delta > std.math.maxInt(i32)) return error.HookUnsupported;
    buffer[jump_position] = 0xE9;
    writeIntToSliceAt(buffer, jump_position + 1, @as(i32, @intCast(delta)));
}

fn caveAllocation(target: usize, patch_address: usize, copied: usize) ?Allocation {
    const stub = findCave(target, patch_address, 14, 0x51, 0, 0) orelse return null;
    const trampoline = findCave(target, patch_address, copied + patch_size, 0x74, stub, 14) orelse return null;
    return .{ .address = stub, .trampoline = trampoline, .kind = .cave };
}

fn findCave(target: usize, patch_address: usize, length: usize, salt: u64, exclude_start: usize, exclude_length: usize) ?usize {
    if (length == 0 or length > 32) return null;
    scanCaves();
    var count: usize = 0;
    for (cave_candidates[0..cave_count]) |cave| {
        if (!caveEligible(cave, target, patch_address, length, exclude_start, exclude_length)) continue;
        count += 1;
    }
    if (count == 0) return null;
    var state = cave_seed ^ @as(u64, @intCast(target)) ^ salt;
    state ^= state << 13;
    state ^= state >> 7;
    state ^= state << 17;
    const selected = state % count;
    var seen: usize = 0;
    for (cave_candidates[0..cave_count]) |cave| {
        if (!caveEligible(cave, target, patch_address, length, exclude_start, exclude_length)) continue;
        if (seen == selected) return cave.start;
        seen += 1;
    }
    return null;
}

fn caveEligible(cave: Cave, target: usize, patch_address: usize, length: usize, exclude_start: usize, exclude_length: usize) bool {
    if (cave.length < length) return false;
    const address = cave.start;
    if (address > target) {
        if (address - target >= near_limit) return false;
    } else if (target - address >= near_limit) return false;
    if (address <= patch_address and patch_address < address + length) return false;
    if (exclude_length != 0 and address + length > exclude_start and address < exclude_start + exclude_length) return false;
    for (entries) |entry| {
        if (entry.target == 0) continue;
        if (entry.slot_address != 0) {
            if (address + length > entry.slot_address and address < entry.slot_address + 16) return false;
        }
        if (entry.trampoline_address != 0) {
            if (address + length > entry.trampoline_address and address < entry.trampoline_address + 32) return false;
        }
    }
    return true;
}

fn scanCaves() void {
    if (caves_scanned) return;
    caves_scanned = true;
    cave_count = 0;
    const maps = readMaps();
    var index: usize = 0;
    var line_start: usize = 0;
    while (index <= maps.len) : (index += 1) {
        const at_end = index == maps.len or maps[index] == '\n';
        if (!at_end) continue;
        const line = maps[line_start..index];
        line_start = index + 1;
        const range = parseExecLine(line) orelse continue;
        var position = range.start;
        while (position < range.end) {
            if (!isPaddingByte(slice(position, 1)[0])) {
                position += 1;
                continue;
            }
            var stop = position;
            while (stop < range.end and isPaddingByte(slice(stop, 1)[0])) : (stop += 1) {}
            if (stop - position >= 14 and cave_count < max_caves) {
                cave_candidates[cave_count] = .{ .start = position, .length = stop - position };
                cave_count += 1;
            }
            position = stop;
        }
    }
}

fn isPaddingByte(byte: u8) bool {
    return byte == 0x00 or byte == 0xCC or byte == 0x90;
}

fn parseExecLine(line: []const u8) ?Range {
    var cursor: usize = 0;
    const start = parseHex(line, &cursor) orelse return null;
    if (cursor >= line.len or line[cursor] != '-') return null;
    cursor += 1;
    const stop = parseHex(line, &cursor) orelse return null;
    if (cursor + 3 >= line.len or line[cursor + 1] != 'r' or line[cursor + 3] != 'x') return null;
    return .{ .start = start, .end = stop };
}

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

const Range = struct { start: usize, end: usize };

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

fn memoryPatchAvailable() bool {
    if (memory_fd == -2) {
        const flags: linux.O = @bitCast(@as(u32, 0o2));
        const fd = linux.openat(linux.AT.FDCWD, "/proc/self/mem", flags, 0);
        memory_fd = if (@as(isize, @bitCast(fd)) >= 0) @intCast(fd) else -1;
    }
    return memory_fd >= 0;
}

fn acquireDataPointer(target: usize) Error!usize {
    for (&data_pages) |*page| {
        if (page.address == 0 or !near(page.address, target)) continue;
        const index = page.used.fetchAdd(1, .monotonic);
        if (index >= page_size / 8) {
            _ = page.used.fetchSub(1, .monotonic);
            continue;
        }
        return page.address + @as(usize, index) * 8;
    }
    for (&data_pages) |*page| {
        if (page.address != 0) continue;
        var attempt: usize = 0;
        while (attempt < 192) : (attempt += 1) {
            const distance = (@as(usize, 1) << 20) + attempt * (@as(usize, 1) << 24);
            const candidate = if (attempt % 2 == 0) target -% distance else target +% distance;
            const hint = candidate & ~(page_size - 1);
            const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
            const result = linux.mmap(@ptrFromInt(hint), page_size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
            if (@as(isize, @bitCast(result)) < 0) continue;
            if (!near(result, target)) {
                _ = linux.munmap(@ptrFromInt(result), page_size);
                continue;
            }
            page.* = .{ .address = result, .used = .init(1) };
            return result;
        }
        return error.HookNoMemory;
    }
    return error.HookNoMemory;
}

fn writeEntryPatch(address: usize, patch: *const [patch_size]u8) Error!void {
    if ((address & 7) != 0) return error.HookUnsupported;
    const page = address & ~(page_size - 1);
    const word_pointer: *u64 = @ptrFromInt(address);
    var word = word_pointer.*;
    @memcpy(std.mem.asBytes(&word)[0..patch_size], patch);
    if (@as(isize, @bitCast(linux.mprotect(@ptrFromInt(page), page_size, .{ .READ = true, .WRITE = true }))) < 0) return error.HookProtectFailed;
    @atomicStore(u64, word_pointer, word, .release);
    if (@as(isize, @bitCast(linux.mprotect(@ptrFromInt(page), page_size, .{ .READ = true, .EXEC = true }))) < 0) return error.HookProtectFailed;
}

fn writeBytes(address: usize, bytes: []const u8) Error!void {
    if (memoryPatchAvailable()) {
        const written = linux.pwrite(memory_fd, bytes.ptr, bytes.len, @intCast(address));
        if (@as(isize, @bitCast(written)) == @as(isize, @intCast(bytes.len))) return;
    }
    const page = address & ~(page_size - 1);
    const offset = address - page;
    if (@as(isize, @bitCast(linux.mprotect(@ptrFromInt(page), page_size, .{ .READ = true, .WRITE = true }))) < 0) return error.HookProtectFailed;
    @memcpy(slice(address, bytes.len), bytes);
    if (@as(isize, @bitCast(linux.mprotect(@ptrFromInt(page), page_size, .{ .READ = true, .EXEC = true }))) < 0) return error.HookProtectFailed;
    _ = offset;
}

fn readBytes(address: usize, count: usize) [patch_size]u8 {
    var result: [patch_size]u8 = @splat(0);
    @memcpy(&result, slice(address, count));
    return result;
}

fn slice(address: usize, count: usize) []u8 {
    return @as([*]u8, @ptrFromInt(address))[0..count];
}

fn readInt(comptime T: type, address: usize) T {
    var result: T = undefined;
    @memcpy(std.mem.asBytes(&result), slice(address, @sizeOf(T)));
    return result;
}

fn writeIntToSlice(buffer: []u8, offset: usize, value: usize) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(buffer[offset..][0..@sizeOf(usize)], bytes);
}

fn writeIntToSliceAt(buffer: []u8, offset: usize, value: anytype) void {
    const bytes = std.mem.asBytes(&value);
    @memcpy(buffer[offset..][0..@sizeOf(@TypeOf(value))], bytes);
}

fn freeSlot() ?usize {
    for (&entries, 0..) |*entry, index| {
        if (entry.target == 0) return index;
    }
    return null;
}
