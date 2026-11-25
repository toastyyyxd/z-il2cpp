const std = @import("std");

pub const il2cpp = @import("il2cpp.zig");
pub const hot = @import("hot/abi.zig");

test {
    std.testing.refAllDecls(@This());
}
