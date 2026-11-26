const std = @import("std");
const z = @import("z_il2cpp");

pub fn main() !void {
    std.debug.print("start\n", .{});
    const loader = z.linux.loader("libc.so.6") catch |err| {
        std.debug.print("loader failed: {s}\n", .{@errorName(err)});
        return;
    };
    std.debug.print("loader ready\n", .{});
    _ = loader;
    if (z.linux.symbol("malloc")) |address| {
        std.debug.print("malloc={x}\n", .{@intFromPtr(address)});
    } else std.debug.print("malloc missing\n", .{});
}
