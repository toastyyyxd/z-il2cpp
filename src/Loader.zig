const builtin = @import("builtin");

pub const Loader = if (builtin.os.tag == .windows) extern struct {
    get_module_handle: *const fn ([*:0]const u16) callconv(.winapi) ?*anyopaque,
    get_proc_address: *const fn (?*anyopaque, [*:0]const u8) callconv(.winapi) ?*anyopaque,
} else extern struct {
    get_module_handle: *const fn ([*:0]const u16) callconv(.c) ?*anyopaque,
    get_proc_address: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
};
