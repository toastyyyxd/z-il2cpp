const std = @import("std");
const Error = @import("error.zig").Error;

pub const Cache = struct {
    header: *Header,
    entries: []Entry,

    const kind_class: u8 = 0;
    const kind_method: u8 = 1;
    const kind_field: u8 = 2;

    pub const Header = extern struct {
        used: usize,
    };

    pub const Entry = extern struct {
        kind: u8,
        owner: ?*anyopaque,
        namespace: ?[*:0]const u8,
        name: ?[*:0]const u8,
        parameter_count: usize,
        value: ?*anyopaque,
    };

    pub fn init(scratch: []u8) Error!Cache {
        if (@intFromPtr(scratch.ptr) % @alignOf(Header) != 0) return error.InvalidScratch;
        const body_offset = alignForward(@sizeOf(Header), @alignOf(Entry));
        if (scratch.len <= body_offset) return error.InvalidScratch;
        const body_pointer = scratch.ptr + body_offset;
        if (@intFromPtr(body_pointer) % @alignOf(Entry) != 0) return error.InvalidScratch;
        const capacity = (scratch.len - body_offset) / @sizeOf(Entry);
        if (capacity == 0) return error.InvalidScratch;
        const header: *Header = @ptrCast(@alignCast(scratch.ptr));
        if (header.used > capacity) return error.InvalidScratch;
        const entries_pointer: [*]Entry = @ptrCast(@alignCast(body_pointer));
        return .{ .header = header, .entries = entries_pointer[0..capacity] };
    }

    pub fn findClass(self: Cache, namespace: [:0]const u8, name: [:0]const u8) ?*anyopaque {
        var index: usize = 0;
        while (index < self.header.used) : (index += 1) {
            const entry = self.entries[index];
            if (entry.kind != kind_class) continue;
            if (!namesEqual(entry.namespace, namespace)) continue;
            if (!namesEqual(entry.name, name)) continue;
            return entry.value;
        }
        return null;
    }

    pub fn putClass(self: Cache, namespace: [:0]const u8, name: [:0]const u8, pointer: ?*anyopaque) Error!void {
        try self.append(.{
            .kind = kind_class,
            .owner = null,
            .namespace = namespace.ptr,
            .name = name.ptr,
            .parameter_count = 0,
            .value = pointer,
        });
    }

    pub fn findMethod(self: Cache, owner: ?*anyopaque, name: [:0]const u8, parameter_count: usize) ?*anyopaque {
        var index: usize = 0;
        while (index < self.header.used) : (index += 1) {
            const entry = self.entries[index];
            if (entry.kind != kind_method) continue;
            if (entry.owner != owner) continue;
            if (entry.parameter_count != parameter_count) continue;
            if (!namesEqual(entry.name, name)) continue;
            return entry.value;
        }
        return null;
    }

    pub fn putMethod(self: Cache, owner: ?*anyopaque, name: [:0]const u8, parameter_count: usize, pointer: ?*anyopaque) Error!void {
        try self.append(.{
            .kind = kind_method,
            .owner = owner,
            .namespace = null,
            .name = name.ptr,
            .parameter_count = parameter_count,
            .value = pointer,
        });
    }

    pub fn findField(self: Cache, owner: ?*anyopaque, name: [:0]const u8) ?*anyopaque {
        var index: usize = 0;
        while (index < self.header.used) : (index += 1) {
            const entry = self.entries[index];
            if (entry.kind != kind_field) continue;
            if (entry.owner != owner) continue;
            if (!namesEqual(entry.name, name)) continue;
            return entry.value;
        }
        return null;
    }

    pub fn putField(self: Cache, owner: ?*anyopaque, name: [:0]const u8, pointer: ?*anyopaque) Error!void {
        try self.append(.{
            .kind = kind_field,
            .owner = owner,
            .namespace = null,
            .name = name.ptr,
            .parameter_count = 0,
            .value = pointer,
        });
    }

    fn append(self: Cache, entry: Entry) Error!void {
        if (self.header.used >= self.entries.len) return error.CacheFull;
        self.entries[self.header.used] = entry;
        self.header.used += 1;
    }

    fn namesEqual(stored: ?[*:0]const u8, desired: []const u8) bool {
        const pointer = stored orelse return false;
        return std.mem.eql(u8, std.mem.span(pointer), desired);
    }

    fn alignForward(offset: usize, alignment: usize) usize {
        return (offset + alignment - 1) & ~(alignment - 1);
    }
};

test "cache stores and finds entries" {
    var buffer: [1024]u8 align(@alignOf(Cache.Entry)) = @splat(0);
    var cache = try Cache.init(buffer[0..]);
    try cache.putClass("UnityEngine", "Screen", @ptrFromInt(0x1000));
    try cache.putMethod(@ptrFromInt(0x1000), "get_width", 0, @ptrFromInt(0x2000));
    try cache.putField(@ptrFromInt(0x1000), "width", @ptrFromInt(0x3000));
    try @import("std").testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1000)), cache.findClass("UnityEngine", "Screen"));
    try @import("std").testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x2000)), cache.findMethod(@ptrFromInt(0x1000), "get_width", 0));
    try @import("std").testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x3000)), cache.findField(@ptrFromInt(0x1000), "width"));
    try @import("std").testing.expectEqual(@as(?*anyopaque, null), cache.findClass("UnityEngine", "Nope"));
}
