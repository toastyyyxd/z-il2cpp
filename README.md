# z-il2cpp

Zig bindings + native shared library for IL2CPP games. Game-agnostic.

- injection, hooks: Frida
- mod logic: native
- JS VM: no per-frame work

Status: reflection layer works in game. Static and instance calls, primitive arguments, managed strings, GC handles, field access.

## Build

```sh
direnv allow        # or nix develop
zig build
zig build test
zig build fmt
zig build shared
zig build smoke-host
```

```sh
FRIDA_GADGET=/path/to/frida-gadget-<ver>-windows-x86_64.dll scripts/smoke.sh
```

```sh
GAME_DIR=/path/to/game FRIDA_GADGET=/path/to/frida-gadget.dll scripts/ingame.sh
```

Requirements: Zig 0.18-dev (flake pin), Wine, Frida gadget 17.26.2 for the dev loop. Hooks target Windows x64 only. Game directory needs the winhttp proxy deployed.

## Dev loop

```sh
GAME_DIR=/path/to/game FRIDA_GADGET=/path/to/frida-gadget-17.26.2-windows-x86_64.dll scripts/session.sh
zig build shared
cp zig-out/shared/* "$GAME_DIR/shared/"
python3 scripts/probe.py
scripts/session.sh stop
```

Session start: about 1 second to gadget port. Probe: about 0.2 seconds against a running game.

## Hooks

Native inline hooks use vendored MinHook. Windows x64 only. The library API is `z_il2cpp.Hooks`.

- `tests/hooks/host.zig`: game-free hook test
- `tests/hooks/spike.zig`: DLL that hooks `il2cpp_domain_get` in game
- `tests/hooks/spike.js`: loads the spike DLL and verifies call counts

```sh
scripts/hooks-smoke.sh
```

MinHook is BSD 2-clause. Source in `third_party/minhook`.

Managed method hooks use the code pointer at offset 0 of `MethodInfo`. Hooking `UnityEngine.Screen.get_width` and invoking it through `Method.invoke` triggers the detour. Offset 8 was not needed for this build.

`z_il2cpp.MinHook` wraps MinHook with typed hooks:

```zig
var hook: ?MinHook.TypedHook(fn (f32) callconv(.c) void) = null;

fn detour(value: f32) callconv(.c) void {
    seen = value;
    hook.?.original(value);
}

hook = try MinHook.TypedHook(fn (f32) callconv(.c) void).install(address, &detour);
hook.?.detach();
```

Detour signatures match the target. Arguments and return values are ordinary Zig parameters and results.

Generic and inflated methods have a different entry ABI. Filter them out before hooking, or pass the hidden method context argument explicitly.

## Native frame execution

`tests/dev` hooks up to 16 `Update` methods from `Assembly-CSharp.dll`:

- classes deriving from `MonoBehaviour`
- non-static methods
- non-generic and non-inflated classes and methods

In-game result: 659887 native detour calls in about 2 seconds, originals executed, game alive, hooks removed cleanly. No JS runs per call. This is the native execution model.


## Development DLL loop

A normal DLL loaded by the agent. Unique file name per build. No game restart.

```sh
GAME_DIR=/path/to/game scripts/dev-probe.sh
```

Iteration: build, copy, load, hook selftest, unload. About 0.26 seconds cached.

Each build uses a new DLL file name. The probe calls FreeLibrary after the hooks are removed.

## Native loader

No Frida. The game loads the mod DLL itself.

- `tests/native/proxy.zig`: minimal winhttp proxy. Forwards the four functions UnityPlayer imports to `winhttp_orig.dll`.
- `tests/native/module.zig`: native mod DLL. Exports `zil2cpp_start`.
- A thread in the proxy DllMain loads `zil2cpp.dll` and calls `zil2cpp_start`.
- The mod DLL waits for `GameAssembly.dll`, hooks `il2cpp_init`, falls back after a timeout, then starts a bootstrap thread.
- Bootstrap: runtime init, read `Screen.width`, install Update hooks, wait three seconds, write `zil2cpp-native-result.json`.

```sh
GAME_DIR=/path/to/game scripts/native-loader.sh
```

Requirements: `winhttp_orig.dll` in the game directory. Write access to the game directory. No gadget, no agent script, no JS.

In-game result: about 5 seconds end to end. Width 1914. 8 Update hooks. Hundreds of thousands of native frame calls in three seconds. No Frida module is loaded.

Startup mode is `init-hook`: the DLL installs a hook on `il2cpp_init` before it runs and bootstraps from the exact `onLeave`. The timeout fallback remains for environments where the DLL loads late.

## Layout

```
build.zig                  build steps: default, shared, smoke-host, hooks-host, hooks-spike, dev-dll, native-proxy, native-dll, test, fmt
src/root.zig               public Zig API
src/Loader.zig             loader function pointers
src/Exports.zig            il2cpp export table and resolution
src/Runtime.zig            runtime init, thread attach, class lookup
src/Class.zig              class lookup, method and field lookup
src/Method.zig             managed invocation
src/Field.zig              field read and write
src/Image.zig              image enumeration
src/Hooks.zig              typed hook API, method entry hooks
src/Cache.zig              scratch-backed lookup cache
src/convert.zig            boxed value conversion
src/error.zig              error set
src/c.zig                  C ABI, State, exports, shared-library root
tools/strip_pe_tls.zig     PE TLS directory strip
tools/gen_manifest.zig     artifact manifest (name, size, sha256)
tests/smoke/host.zig       smoke host, loads frida-gadget.dll
tests/smoke/agent.js       smoke agent, maps artifact and asserts ABI
tests/support/frames.zig    shared Update hook helper
tests/ingame/probe.js      dev probe agent
tests/ingame/agent.js      one-shot probe agent
scripts/smoke.sh           smoke orchestration
scripts/session.sh         persistent listen-mode game session
scripts/probe.py           host probe runner
scripts/ingame.sh          one-shot probe orchestration
scripts/hooks-smoke.sh     game-free hook test
scripts/dev-probe.sh       dev DLL loop
scripts/native-loader.sh   Frida-free loader test
tests/native/proxy.zig     winhttp proxy, loads the mod DLL
tests/native/module.zig    native mod DLL, startup and frame hooks
tests/dev/module.zig       dev DLL, managed hook selftest
tests/dev/probe.js         dev DLL probe
tests/hooks/host.zig       game-free MinHook test
tests/hooks/spike.zig      in-game hook spike DLL
tests/hooks/spike.js       in-game hook spike probe
third_party/minhook        vendored MinHook (BSD 2-clause)
```

## Zig API

```zig
const runtime = try Runtime.init(loader, scratch);

const screen = try runtime.findClass("UnityEngine", "Screen");
const width_method = try screen.findMethod("get_width", 0);
const width = try width_method.invoke(.{}, i32);

const camera = try runtime.findClass("UnityEngine", "Camera");
const main_method = try camera.findMethod("get_main", 0);
const instance = try main_method.invoke(.{}, ?*anyopaque);
const fov_method = try camera.findMethod("get_fieldOfView", 0);
const fov = try fov_method.invokeOn(instance, .{}, f32);

const text = try ManagedString.fromUtf8(runtime, "hello");
var buffer: [64]u8 = undefined;
const utf8 = try text.toUtf8(buffer[0..]);

const handle = try Handle.acquire(runtime, instance, .strong);
defer handle.release();
const target = handle.target();

const image = try runtime.findImage("Assembly-CSharp.dll");
const update_class = try image.classAt(0);
const base = update_class.derivesFromName("MonoBehaviour");

const update = try update_class.findMethod("Update", 0);
const entry = try update.entryPoint();

const hook = try Hooks.hookMethod(fn (?*anyopaque) callconv(.c) void, update, &detour);
defer hook.detach();

const empty = try string_class.findField("Empty");
if (empty.isStatic()) {
    const value = try empty.readStatic(?*anyopaque);
    try empty.writeStatic(value);
}

const base = try object_class.findMethod("ToString", 0);
const resolved = try base.resolveVirtual(instance);
const virtual_hook = try Hooks.hookVirtualMethod(fn (?*anyopaque) callconv(.c) ?*anyopaque, base, instance, &detour);
defer virtual_hook.detach();
```

```zig
const field = try klass.findField("m_Value");
const value = try field.read(instance, i32);
try field.write(instance, value + 1);

if (field.isStatic()) {
    const static_value = try field.readStatic(i32);
    try field.writeStatic(static_value);
}

var fields = klass.fields();
while (fields.next()) |entry| {
    const type_name = entry.typeName();
}

var methods = klass.methods();
while (methods.next()) |method| {
    const method_name = method.name();
    const parameter_count = method.parameterCount();
}
```

Struct arguments and returns use Zig `extern struct` types. Layout must match the managed layout. Supported argument types: bool, integers, floats, enums, pointers, extern structs. Return types add void and `?*anyopaque` references.

Managed exceptions have a detailed path.

```zig
const outcome = try method.invokeCatching(.{argument}, i32);
switch (outcome) {
    .value => |value| {},
    .exception => |exception| {
        const class_name = exception.className();
        var message_buffer: [256]u8 = undefined;
        const message = try exception.message(message_buffer[0..]);
        var trace_buffer: [512]u8 = undefined;
        const trace = try exception.stackTrace(trace_buffer[0..]);
    },
}
```

Message and stack trace come from the managed `Exception.Message` and `Exception.StackTrace` getters. `Method.invoke` still collapses to `error.ManagedException`.

`Method.isVirtual`, `Method.resolveVirtual`, and `Method.virtualEntryPoint` cover overrides. `Hooks.hookVirtualMethod` resolves the override for an instance and hooks it.

No allocator. Scratch is caller memory. One thread, attached in `Runtime.init`. Cache lives in scratch.

Reference values returned as `?*anyopaque` are transient. Store them through `Handle`. Static methods use `invoke`. Instance methods use `invokeOn`.

## C ABI

`State`: 64 bytes, align 8.

| offset | size | field |
| --- | --- | --- |
| 0 | 4 | `abi_version` |
| 4 | 4 | `init_magic` = `0x324c315a` ("Z1L2") |
| 8 | 4 | `flags` |
| 12 | 4 | padding |
| 16 | 8 | `tick_count` |
| 24 | 8 | `last_frame` |
| 32 | 32 | `reserved` |

`reserved` slots.

```
[0] Loader pointer
[1] scratch pointer
[2] scratch length
[3] scratch initialized marker
```

Exports.

| export | result |
| --- | --- |
| `zil2cpp_abi` | ABI version |
| `zil2cpp_state_size` | `State` size |
| `zil2cpp_init` | ABI version, 0 on bad magic |
| `zil2cpp_runtime_init` | ABI version, negative error |
| `zil2cpp_tick` | tick count |
| `zil2cpp_tick_count` | tick count |
| `zil2cpp_last_frame` | last frame |
| `zil2cpp_probe_screen_width` | screen width, negative error |

Error codes.

```
-1 not initialized
-2 invalid scratch
-3 GameAssembly not loaded
-4 missing il2cpp export
-5 no domain
-6 no assemblies
-7 class not found
-8 method not found
-9 field not found
-10 null instance
-11 invoke failed
-12 managed exception
-13 unbox failed
-14 cache full
-15 arguments not supported
-18 argument count mismatch
-19 null object
-20 handle creation failed
-21 string conversion failed
-22 invalid buffer
-23 hook failed
-24 image not found
-16 virtual method not supported
-17 invalid parameter count
```

Host side.

- allocate and zero `State`
- allocate `Loader` with two Windows loader pointers
- allocate scratch, at least 1024 bytes, 4096 recommended
- retain the module wrapper, GC unmaps it
- strip PE TLS directory, required for Wine/Proton
- call from one thread
- handle values are pointer-sized in this build; treat them as opaque
- weak handles are not available, the export is missing

Version: `abi_version` in `src/c.zig`. Increment on incompatible ABI change.

## Artifacts

`zig build shared` writes:

```
zig-out/shared/z-il2cpp-windows-x86_64.pe
zig-out/shared/z-il2cpp-linux-x86_64.so
zig-out/shared/z-il2cpp-linux-aarch64.so
zig-out/shared/manifest.json
```
