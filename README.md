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

Requirements: Zig 0.18-dev (flake pin), Wine, Frida gadget 17.26.2 for the dev loop. Game directory needs the winhttp proxy deployed.

## Dev loop

```sh
GAME_DIR=/path/to/game FRIDA_GADGET=/path/to/frida-gadget-17.26.2-windows-x86_64.dll scripts/session.sh
zig build shared
cp zig-out/shared/* "$GAME_DIR/shared/"
python3 scripts/probe.py
scripts/session.sh stop
```

Session start: about 1 second to gadget port. Probe: about 0.2 seconds against a running game.

## Layout

```
build.zig                  build steps: default, shared, smoke-host, test, fmt
src/root.zig               public Zig API
src/Loader.zig             loader function pointers
src/Exports.zig            il2cpp export table and resolution
src/Runtime.zig            runtime init, thread attach, class lookup
src/Class.zig              class lookup, method and field lookup
src/Method.zig             managed invocation
src/Field.zig              field read and write
src/Cache.zig              scratch-backed lookup cache
src/convert.zig            boxed value conversion
src/error.zig              error set
src/c.zig                  C ABI, State, exports, shared-library root
tools/strip_pe_tls.zig     PE TLS directory strip
tools/gen_manifest.zig     artifact manifest (name, size, sha256)
tests/smoke/host.zig       smoke host, loads frida-gadget.dll
tests/smoke/agent.js       smoke agent, maps artifact and asserts ABI
tests/ingame/probe.js      dev probe agent
tests/ingame/agent.js      one-shot probe agent
scripts/smoke.sh           smoke orchestration
scripts/session.sh         persistent listen-mode game session
scripts/probe.py           host probe runner
scripts/ingame.sh          one-shot probe orchestration
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
```

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
