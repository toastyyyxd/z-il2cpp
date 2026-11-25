const abi = @import("abi.zig");

export fn hot_abi() callconv(.c) u32 {
    return abi.abi_version;
}

export fn hot_state_size() callconv(.c) u32 {
    return @sizeOf(abi.State);
}

export fn hot_init(state: ?*abi.State, magic: u32) callconv(.c) u32 {
    const s = state orelse return 0;
    s.abi_version = abi.abi_version;
    s.init_magic = magic;
    s.flags = 0;
    s._padding = 0;
    s.tick_count = 0;
    s.last_frame = 0;
    s.reserved = .{ 0, 0, 0, 0 };
    return if (magic == abi.init_magic) abi.abi_version else 0;
}

export fn hot_tick(state: ?*abi.State, frame: u64) callconv(.c) u64 {
    const s = state orelse return 0;
    s.tick_count +%= 1;
    s.last_frame = frame;
    return s.tick_count;
}

export fn hot_tick_count(state: ?*const abi.State) callconv(.c) u64 {
    const s = state orelse return 0;
    return s.tick_count;
}

export fn hot_last_frame(state: ?*const abi.State) callconv(.c) u64 {
    const s = state orelse return 0;
    return s.last_frame;
}

test {
    _ = abi;
}
