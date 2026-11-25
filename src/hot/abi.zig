const std = @import("std");

pub const abi_version: u32 = 1;

pub const init_magic: u32 = 0x324c315a;

pub const State = extern struct {
    abi_version: u32,
    init_magic: u32,
    flags: u32,
    _padding: u32 = 0,
    tick_count: u64,
    last_frame: u64,
    reserved: [4]u64 = .{ 0, 0, 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(State) == 64);
    std.debug.assert(@alignOf(State) == 8);
    std.debug.assert(@offsetOf(State, "tick_count") == 16);
    std.debug.assert(@offsetOf(State, "reserved") == 32);
}

test "init magic bytes" {
    if (@import("builtin").cpu.arch.endian() == .little) {
        try std.testing.expectEqualStrings("Z1L2", std.mem.asBytes(&init_magic)[0..4]);
    }
}

test "state layout" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(State));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(State, "tick_count"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(State, "last_frame"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(State, "reserved"));
}
