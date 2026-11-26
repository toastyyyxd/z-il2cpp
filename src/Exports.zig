const Loader = @import("Loader.zig").Loader;
const Error = @import("error.zig").Error;

pub const Exports = struct {
    domain_get: *const fn () callconv(.c) ?*anyopaque,
    domain_get_assemblies: *const fn (?*anyopaque, *usize) callconv(.c) [*]?*anyopaque,
    assembly_get_image: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    class_from_name: *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque,
    class_get_method_from_name: *const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) ?*anyopaque,
    class_get_field_from_name: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque,
    method_get_param_count: *const fn (?*anyopaque) callconv(.c) u32,
    field_get_offset: *const fn (?*anyopaque) callconv(.c) usize,
    runtime_invoke: *const fn (?*anyopaque, ?*anyopaque, ?[*]?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque,
    object_unbox: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    thread_attach: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    thread_current: *const fn () callconv(.c) ?*anyopaque,
    image_get_class_count: *const fn (?*anyopaque) callconv(.c) usize,
    image_get_class: *const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque,
    class_get_name: *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    image_get_name: *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    class_get_parent: *const fn (?*anyopaque) callconv(.c) ?*anyopaque,
    method_get_flags: *const fn (?*anyopaque, *u32) callconv(.c) u32,
    class_is_generic: *const fn (?*anyopaque) callconv(.c) bool,
    class_is_inflated: *const fn (?*anyopaque) callconv(.c) bool,
    method_is_generic: *const fn (?*anyopaque) callconv(.c) bool,
    method_is_inflated: *const fn (?*anyopaque) callconv(.c) bool,
    gchandle_new: *const fn (?*anyopaque, bool) callconv(.c) usize,
    gchandle_get_target: *const fn (usize) callconv(.c) ?*anyopaque,
    gchandle_free: *const fn (usize) callconv(.c) void,
    string_new: *const fn ([*:0]const u8) callconv(.c) ?*anyopaque,
    string_length: *const fn (?*anyopaque) callconv(.c) i32,
    string_chars: *const fn (?*anyopaque) callconv(.c) ?[*]const u16,
    gc_collect: *const fn (i32) callconv(.c) void,

    pub fn resolve(loader: Loader, module: ?*anyopaque) Error!Exports {
        return .{
            .domain_get = try resolveOne(*const fn () callconv(.c) ?*anyopaque, loader, module, "il2cpp_domain_get"),
            .domain_get_assemblies = try resolveOne(*const fn (?*anyopaque, *usize) callconv(.c) [*]?*anyopaque, loader, module, "il2cpp_domain_get_assemblies"),
            .assembly_get_image = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_assembly_get_image"),
            .class_from_name = try resolveOne(*const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_from_name"),
            .class_get_method_from_name = try resolveOne(*const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_get_method_from_name"),
            .class_get_field_from_name = try resolveOne(*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_get_field_from_name"),
            .method_get_param_count = try resolveOne(*const fn (?*anyopaque) callconv(.c) u32, loader, module, "il2cpp_method_get_param_count"),
            .field_get_offset = try resolveOne(*const fn (?*anyopaque) callconv(.c) usize, loader, module, "il2cpp_field_get_offset"),
            .runtime_invoke = try resolveOne(*const fn (?*anyopaque, ?*anyopaque, ?[*]?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_runtime_invoke"),
            .object_unbox = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_object_unbox"),
            .thread_attach = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_thread_attach"),
            .thread_current = try resolveOne(*const fn () callconv(.c) ?*anyopaque, loader, module, "il2cpp_thread_current"),
            .image_get_class_count = try resolveOne(*const fn (?*anyopaque) callconv(.c) usize, loader, module, "il2cpp_image_get_class_count"),
            .image_get_class = try resolveOne(*const fn (?*anyopaque, usize) callconv(.c) ?*anyopaque, loader, module, "il2cpp_image_get_class"),
            .class_get_name = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, loader, module, "il2cpp_class_get_name"),
            .image_get_name = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?[*:0]const u8, loader, module, "il2cpp_image_get_name"),
            .class_get_parent = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?*anyopaque, loader, module, "il2cpp_class_get_parent"),
            .method_get_flags = try resolveOne(*const fn (?*anyopaque, *u32) callconv(.c) u32, loader, module, "il2cpp_method_get_flags"),
            .class_is_generic = try resolveOne(*const fn (?*anyopaque) callconv(.c) bool, loader, module, "il2cpp_class_is_generic"),
            .class_is_inflated = try resolveOne(*const fn (?*anyopaque) callconv(.c) bool, loader, module, "il2cpp_class_is_inflated"),
            .method_is_generic = try resolveOne(*const fn (?*anyopaque) callconv(.c) bool, loader, module, "il2cpp_method_is_generic"),
            .method_is_inflated = try resolveOne(*const fn (?*anyopaque) callconv(.c) bool, loader, module, "il2cpp_method_is_inflated"),
            .gchandle_new = try resolveOne(*const fn (?*anyopaque, bool) callconv(.c) usize, loader, module, "il2cpp_gchandle_new"),
            .gchandle_get_target = try resolveOne(*const fn (usize) callconv(.c) ?*anyopaque, loader, module, "il2cpp_gchandle_get_target"),
            .gchandle_free = try resolveOne(*const fn (usize) callconv(.c) void, loader, module, "il2cpp_gchandle_free"),
            .string_new = try resolveOne(*const fn ([*:0]const u8) callconv(.c) ?*anyopaque, loader, module, "il2cpp_string_new"),
            .string_length = try resolveOne(*const fn (?*anyopaque) callconv(.c) i32, loader, module, "il2cpp_string_length"),
            .string_chars = try resolveOne(*const fn (?*anyopaque) callconv(.c) ?[*]const u16, loader, module, "il2cpp_string_chars"),
            .gc_collect = try resolveOne(*const fn (i32) callconv(.c) void, loader, module, "il2cpp_gc_collect"),
        };
    }
};

fn resolveOne(comptime T: type, loader: Loader, module: ?*anyopaque, name: [*:0]const u8) Error!T {
    const raw = loader.get_proc_address(module, name) orelse return error.MissingExport;
    return @ptrCast(@alignCast(raw));
}
