extern "kernel32" fn LoadLibraryW(path: [*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

const host_lifetime_ms = 20_000;

pub fn main() void {
    _ = LoadLibraryW(@import("std").unicode.utf8ToUtf16LeStringLiteral("frida-gadget.dll"));
    Sleep(host_lifetime_ms);
}
