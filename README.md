# z-il2cpp

Zig bindings + native hot module for IL2CPP games. Game-agnostic.

- injection, hooks: Frida
- mod logic: native
- JS VM: no per-frame work

Status: M0. Hot module and game-free harness work. `src/il2cpp.zig` is a stub.

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

Requirements: Zig 0.18-dev (flake pin), Wine for the smoke test, Frida gadget >= 17.25.

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
scripts/smoke.sh           smoke orchestration
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

Exports: `hot_abi`, `hot_state_size`, `hot_init`, `hot_tick`, `hot_tick_count`, `hot_last_frame`.

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
