const Runtime = @import("Runtime.zig").Runtime;
const Error = @import("error.zig").Error;

pub const Kind = enum {
    strong,
    pinned,
};

pub const Handle = struct {
    runtime: Runtime,
    value: usize,

    pub fn acquire(runtime: Runtime, object: ?*anyopaque, kind: Kind) Error!Handle {
        const pointer = object orelse return error.NullObject;
        const value = runtime.exports.gchandle_new(pointer, kind == .pinned);
        if (value == 0) return error.HandleFailed;
        return .{ .runtime = runtime, .value = value };
    }

    pub fn target(self: Handle) ?*anyopaque {
        return self.runtime.exports.gchandle_get_target(self.value);
    }

    pub fn release(self: Handle) void {
        self.runtime.exports.gchandle_free(self.value);
    }
};
