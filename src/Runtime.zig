const Loader = @import("Loader.zig").Loader;
const Exports = @import("Exports.zig").Exports;
const Cache = @import("Cache.zig").Cache;
const Error = @import("error.zig").Error;
const Class = @import("Class.zig").Class;
const Image = @import("Image.zig").Image;
const std = @import("std");

const game_assembly_name = [16:0]u16{
    'G', 'a', 'm', 'e', 'A', 's', 's', 'e', 'm', 'b', 'l', 'y', '.', 'd', 'l', 'l',
};

pub const Runtime = struct {
    loader: Loader,
    exports: Exports,
    domain: ?*anyopaque,
    cache: Cache,

    pub fn init(loader: Loader, scratch: []u8) Error!Runtime {
        const module = loader.get_module_handle(&game_assembly_name) orelse return error.ModuleNotFound;
        const exports = try Exports.resolve(loader, module);
        const domain = exports.domain_get() orelse return error.NoDomain;
        if (exports.thread_current() == null) {
            _ = exports.thread_attach(domain);
        }
        const cache = try Cache.init(scratch);
        return .{
            .loader = loader,
            .exports = exports,
            .domain = domain,
            .cache = cache,
        };
    }

    pub fn classOf(self: Runtime, object: ?*anyopaque) Error!Class {
        const instance = object orelse return error.NullObject;
        const pointer = self.exports.object_get_class(instance) orelse return error.ClassNotFound;
        return .{ .runtime = self, .pointer = pointer };
    }

    pub fn findImage(self: Runtime, name: [:0]const u8) Error!Image {
        const domain = self.domain orelse return error.NoDomain;
        var count: usize = 0;
        const assemblies = self.exports.domain_get_assemblies(domain, &count);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const image = self.exports.assembly_get_image(assemblies[index]) orelse continue;
            const image_name = self.exports.image_get_name(image) orelse continue;
            if (std.mem.eql(u8, std.mem.span(image_name), name)) {
                return .{ .runtime = self, .pointer = image };
            }
        }
        return error.ImageNotFound;
    }

    pub fn findClass(self: Runtime, namespace: [:0]const u8, name: [:0]const u8) Error!Class {
        if (self.cache.findClass(namespace, name)) |pointer| {
            return .{ .runtime = self, .pointer = pointer };
        }
        const domain = self.domain orelse return error.NoDomain;
        var count: usize = 0;
        const assemblies = self.exports.domain_get_assemblies(domain, &count);
        if (count == 0) return error.NoAssemblies;
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const image = self.exports.assembly_get_image(assemblies[index]) orelse continue;
            const pointer = self.exports.class_from_name(image, namespace.ptr, name.ptr) orelse continue;
            try self.cache.putClass(namespace, name, pointer);
            return .{ .runtime = self, .pointer = pointer };
        }
        return error.ClassNotFound;
    }
};
