const std = @import("std");
const linux = std.os.linux;

const page_size: usize = 4096;

pub fn Table(comptime T: type, comptime chunk_size: usize) type {
    return struct {
        const Self = @This();

        pub const Chunk = struct {
            items: [chunk_size]T = @splat(.{}),
            next: ?*Chunk = null,
        };

        first: ?*Chunk = null,
        chunk_count: usize = 0,

        pub fn item(self: *Self, index: usize) *T {
            var chunk = self.first orelse @panic("chunked table is empty");
            var remaining = index / chunk_size;
            while (remaining > 0) : (remaining -= 1) chunk = chunk.next.?;
            return &chunk.items[index % chunk_size];
        }

        pub fn appendChunk(self: *Self) ?usize {
            const size = std.mem.alignForward(usize, @sizeOf(Chunk), page_size);
            const flags: linux.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
            const result = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, flags, -1, 0);
            if (@as(isize, @bitCast(result)) < 0) return null;
            const created: *Chunk = @ptrCast(@alignCast(@as([*]u8, @ptrFromInt(result))));
            if (self.first) |first_chunk| {
                var tail = first_chunk;
                while (tail.next) |next| tail = next;
                tail.next = created;
            } else {
                self.first = created;
            }
            self.chunk_count += 1;
            return (self.chunk_count - 1) * chunk_size;
        }

        pub fn deinit(self: *Self) void {
            var chunk = self.first;
            while (chunk) |current| : (chunk = current.next) {
                _ = linux.munmap(@ptrCast(current), std.mem.alignForward(usize, @sizeOf(Chunk), page_size));
            }
            self.* = .{};
        }
    };
}
