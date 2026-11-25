# z-il2cpp

Zig bindings + native hot module for IL2CPP games. Game-agnostic.

- injection, hooks: Frida
- mod logic: native
- JS VM: no per-frame work

Status: hot module, game-free harness, native screen width read inside game. `src/il2cpp.zig` is a stub.

## Build

```sh
direnv allow        # or nix develop
zig build
zig build test
zig build fmt
zig build hot
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
zig build hot
cp zig-out/hot/hot-windows-x86_64.pe "$GAME_DIR/hot/"
python3 scripts/probe.py
scripts/session.sh stop
```

Session start: about 1 second to gadget port. Probe: about 0.2 seconds against a running game.

## Layout

```
build.zig                  build steps: default, hot, smoke-host, test, fmt
src/root.zig               public module
src/il2cpp.zig             il2cpp_* bindings (stub)
src/hot/abi.zig            hot module ABI v1
src/hot/module.zig         hot module, shared-library root
tools/strip_pe_tls.zig     PE TLS directory strip
tools/gen_manifest.zig     artifact manifest (name, size, sha256)
tests/smoke/host.zig       smoke host, loads frida-gadget.dll
tests/smoke/agent.js       smoke agent, maps module and asserts ABI
tests/ingame/agent.js      in-game agent, native screen width probe
scripts/smoke.sh           smoke orchestration
scripts/session.sh         persistent listen-mode game session
scripts/probe.py           host probe runner, connects to session
tests/ingame/probe.js      probe agent for the persistent session
scripts/ingame.sh          one-shot in-game probe orchestration
```

## Hot module ABI v1

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

`reserved[0]`: host API pointer. Set by `hot_bind_host`.

`HostApi`: two Windows loader pointers.

| offset | field |
| --- | --- |
| 0 | `GetModuleHandleW` |
| 8 | `GetProcAddress` |

Exports:

| export | result |
| --- | --- |
| `hot_abi` | ABI version |
| `hot_state_size` | `State` size |
| `hot_init` | ABI version, 0 on bad magic |
| `hot_bind_host` | ABI version, 0 on null input |
| `hot_tick` | tick count |
| `hot_tick_count` | tick count |
| `hot_last_frame` | last frame |
| `hot_probe_screen_width` | screen width, or negative error |

Probe errors:

```
-1 no state
-2 no host api
-3 GameAssembly not loaded
-4 missing il2cpp export
-5 no assemblies
-6 no Screen class
-7 no get_width method
-8 invoke returned null
-9 managed exception
-10 unbox returned null
```

Host side:
- allocate and zero `State`
- retain the module wrapper, GC unmaps it
- strip PE TLS directory, required for Wine/Proton
- call from one thread

Version: `abi_version` in `src/hot/abi.zig`. Increment on incompatible ABI change.

## Artifacts

`zig build hot` writes:

```
zig-out/hot/hot-windows-x86_64.pe
zig-out/hot/hot-linux-x86_64.so
zig-out/hot/hot-linux-aarch64.so
zig-out/hot/manifest.json
```
