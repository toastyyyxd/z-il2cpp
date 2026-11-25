const Loader = @import("Loader.zig").Loader;
const Error = @import("error.zig").Error;

pub const Exports = struct {
    domain_get: *const fn () callconv(.c) ?*anyopaque,
    domain_get_assemblies: *const fn (?*anyopaque, *usize) callconv(.c) [*]?*anyopaque,
    assembly_get_image: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    class_from_name: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    class_get_method_from_name: *const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) ?*anyopaque,
    class_get_field_from_name: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    field_get_offset: *const fn (?*anyopaque) callconv(.c) usize,
    runtime_invoke: *const fn (?*anyopaque, ?*anyopaque, ?[*]?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque,
    object_unbox: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    thread_attach: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    thread_current: *const fn () callconv(.c) ?*anyopaque,

    pub fn resolve(loader: Loader, module: ?*anyopaque) Error!Exports {
        return .{
            .domain_get = try resolveOne(*const fn () callconv(.c) ?*anyopaque, loader, module, "il2cpp_domain_get"),
            .domain_get_assemblies = try resolveOne(*const fn (?*anyopaque, *usize) callconv(.c) [*]?*anyopaque, loader, module, "il2cpp_domain_get_assemblies"),
            .assembly_get_image = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_assembly_get_image"),
            .class_from_name = try resolveOne(*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_from_name"),
            .class_get_method_from_name = try resolveOne(*const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_get_method_from_name"),
            .class_get_field_from_name = try resolveOne(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_get_field_from_name"),
            .field_get_offset = try resolveOne(*const fn (?*anyopaque) callconv(.c) usize, loader, module, "il2cpp_field_get_offset"),
            .runtime_invoke = try resolveOne(*const fn (?*anyopaque, ?*anyopaque, ?[*]?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_runtime_invoke"),
            .object_unbox = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_object_unbox"),
            .thread_attach = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_thread_attach"),
            .thread_current = try resolveOne(*const fn () callconv(.c) ?*anyopaque, loader, module, "il2cpp_thread_current"),
        };
    }
};

fn resolveOne(comptime T: type, loader: Loader, module: ?*anyopaque, name: [*:0]const u8) Error!T {
    const raw = loader.get_proc_address(module, name) orelse return error.MissingExport;
    return @ptrCast(@alignCast(raw));
}
