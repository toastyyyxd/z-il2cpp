const abi = @import("abi.zig");

const game_assembly_name = [16:0]u16{
    'G', 'a', 'm', 'e', 'A', 's', 's', 'e', 'm', 'b', 'l', 'y', '.', 'd', 'l', 'l',
};

const err_no_state: i32 = -1;
const err_no_host_api: i32 = -2;
const err_no_module: i32 = -3;
const err_missing_export: i32 = -4;
const err_no_assemblies: i32 = -5;
const err_no_screen_class: i32 = -6;
const err_no_width_method: i32 = -7;
const err_invoke_null: i32 = -8;
const err_managed_exception: i32 = -9;
const err_unbox_null: i32 = -10;

const DomainGet = *const fn () callconv(.c) ?*anyopaque;
const DomainGetAssemblies = *const fn (?*anyopaque, *usize) callconv(.c) [*]?*anyopaque;
const ThreadAttach = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const AssemblyGetImage = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
const ClassFromName = *const fn (?*anyopaque, [*:0]const u8, [*:0]const u8) callconv(.c) ?*anyopaque;
const ClassGetMethodFromName = *const fn (?*anyopaque, [*:0]const u8, i32) callconv(.c) ?*anyopaque;
const RuntimeInvoke = *const fn (?*anyopaque, ?*anyopaque, ?[*]?*anyopaque, ?*?*anyopaque) callconv(.c) ?*anyopaque;
const ObjectUnbox = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;

fn fnPtr(comptime T: type, raw: ?*anyopaque) ?T {
    const pointer = raw orelse return null;
    return @ptrCast(@alignCast(pointer));
}

fn resolve(host: *const abi.HostApi, module: ?*anyopaque, name: [*:0]const u8) ?*anyopaque {
    return host.get_proc_address(module, name);
}

export fn hot_abi() callconv(.c) u32 {
    return abi.abi_version;
}

export fn hot_state_size() callconv(.c) u32 {
    return @sizeOf(abi.State);
}

export fn hot_init(state: ?*abi.State, magic: u32) callconv(.c) u32 {
    const s = state orelse return 0;
    s.abi_version = abi.abi_version;
    s.init_magic = magic;
    s.flags = 0;
    s._padding = 0;
    s.tick_count = 0;
    s.last_frame = 0;
    s.reserved = .{ 0, 0, 0, 0 };
    return if (magic == abi.init_magic) abi.abi_version else 0;
}

export fn hot_bind_host(state: ?*abi.State, host: ?*const abi.HostApi) callconv(.c) u32 {
    const s = state orelse return 0;
    const h = host orelse return 0;
    s.reserved[0] = @intFromPtr(h);
    return abi.abi_version;
}

export fn hot_tick(state: ?*abi.State, frame: u64) callconv(.c) u64 {
    const s = state orelse return 0;
    s.tick_count +%= 1;
    s.last_frame = frame;
    return s.tick_count;
}

export fn hot_tick_count(state: ?*const abi.State) callconv(.c) u64 {
    const s = state orelse return 0;
    return s.tick_count;
}

export fn hot_last_frame(state: ?*const abi.State) callconv(.c) u64 {
    const s = state orelse return 0;
    return s.last_frame;
}

fn probe(state: ?*abi.State, stage: u32) i32 {
    const s = state orelse return err_no_state;
    if (s.reserved[0] == 0) return err_no_host_api;
    const host: *const abi.HostApi = @ptrFromInt(@as(usize, @intCast(s.reserved[0])));

    const module = host.get_module_handle(&game_assembly_name) orelse return err_no_module;
    if (stage == 0) return 1;

    const domain_get = fnPtr(DomainGet, resolve(host, module, "il2cpp_domain_get")) orelse return err_missing_export;
    const domain_get_assemblies = fnPtr(DomainGetAssemblies, resolve(host, module, "il2cpp_domain_get_assemblies")) orelse return err_missing_export;
    const assembly_get_image = fnPtr(AssemblyGetImage, resolve(host, module, "il2cpp_assembly_get_image")) orelse return err_missing_export;
    const class_from_name = fnPtr(ClassFromName, resolve(host, module, "il2cpp_class_from_name")) orelse return err_missing_export;
    const class_get_method_from_name = fnPtr(ClassGetMethodFromName, resolve(host, module, "il2cpp_class_get_method_from_name")) orelse return err_missing_export;
    const runtime_invoke = fnPtr(RuntimeInvoke, resolve(host, module, "il2cpp_runtime_invoke")) orelse return err_missing_export;
    const object_unbox = fnPtr(ObjectUnbox, resolve(host, module, "il2cpp_object_unbox")) orelse return err_missing_export;
    const thread_attach = fnPtr(ThreadAttach, resolve(host, module, "il2cpp_thread_attach")) orelse return err_missing_export;
    if (stage == 1) return 1;

    const domain = domain_get() orelse return err_no_state;
    if (stage == 2) return 1;

    _ = thread_attach(domain);
    if (stage == 3) return 1;

    var count: usize = 0;
    const assemblies = domain_get_assemblies(domain, &count);
    if (count == 0) return err_no_assemblies;
    if (stage == 4) return @intCast(@min(count, 1000000));

    var screen: ?*anyopaque = null;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const image = assembly_get_image(assemblies[index]) orelse continue;
        screen = class_from_name(image, "UnityEngine", "Screen");
        if (screen != null) break;
    }
    const klass = screen orelse return err_no_screen_class;
    if (stage == 5) return 1;

    const method = class_get_method_from_name(klass, "get_width", 0) orelse return err_no_width_method;
    if (stage == 6) return 1;

    var exception: ?*anyopaque = null;
    const result = runtime_invoke(method, null, null, &exception) orelse return err_invoke_null;
    if (exception != null) return err_managed_exception;

    const unboxed = object_unbox(result) orelse return err_unbox_null;
    const width: *const i32 = @ptrCast(@alignCast(unboxed));
    return width.*;
}

export fn hot_probe_screen_width(state: ?*abi.State) callconv(.c) i32 {
    return probe(state, 7);
}

export fn hot_probe_stage(state: ?*abi.State, stage: u32) callconv(.c) i32 {
    return probe(state, stage);
}

test {
    _ = abi;
}
