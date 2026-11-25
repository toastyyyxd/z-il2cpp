const ABI_VERSION = 1;
const INIT_MAGIC = 0x324c315a;

const result = {
    ok: false,
    frida: Frida.version,
    platform: Process.platform,
    arch: Process.arch,
    module: "hot/hot-windows-x86_64.pe",
    screen_width: null,
    status: null,
};

try {
    File.writeAllText("probe-boot.json", JSON.stringify({ frida: Frida.version, cwd: Process.getCurrentDir() }));
} catch (_) {}

function stageWrite(name, extra) {
    try {
        File.writeAllText("probe-stage.json", JSON.stringify({ frida: Frida.version, stage: name, extra: extra ?? null }));
    } catch (_) {}
}

function stage(name, extra) {
    try {
        File.writeAllText("probe-stage.json", JSON.stringify({ frida: Frida.version, stage: name, extra: extra ?? null }));
    } catch (_) {}
}

function writeResult() {
    File.writeAllText("probe-result.json", JSON.stringify(result, null, 2) + "\n");
    console.log("[probe] " + JSON.stringify(result));
}

function fail(message) {
    result.error = message;
    writeResult();
}

function main() {
    stage("map-start");
    let module;
    try {
        const bytes = File.readAllBytes(result.module);
        module = new CModule(bytes);
        globalThis.__hotModule = module;
    } catch (error) {
        fail("map: " + (error instanceof Error ? error.message : String(error)));
        return;
    }

    stage("mapped");
    const required = ["hot_abi", "hot_state_size", "hot_init", "hot_bind_host", "hot_probe_screen_width", "hot_probe_stage"];
    const missing = required.filter((name) => module[name] === undefined);
    if (missing.length !== 0) {
        fail("exports: " + missing.join(","));
        return;
    }

    const abi = new NativeFunction(module.hot_abi, "uint", [])();
    if (abi !== ABI_VERSION) {
        fail("abi: " + abi);
        return;
    }

    const stateSize = new NativeFunction(module.hot_state_size, "uint", [])();
    const state = Memory.alloc(stateSize);
    stage("size", stateSize);
    const init = new NativeFunction(module.hot_init, "uint", ["pointer", "uint"]);
    if (init(state, INIT_MAGIC) !== ABI_VERSION) {
        fail("init");
        return;
    }

    stage("inited");
    try {
        const kernel32 = Process.getModuleByName("kernel32.dll");
        const host = Memory.alloc(Process.pointerSize * 2);
        host.writePointer(kernel32.getExportByName("GetModuleHandleW"));
        host.add(Process.pointerSize).writePointer(kernel32.getExportByName("GetProcAddress"));
        const bind = new NativeFunction(module.hot_bind_host, "uint", ["pointer", "pointer"]);
        if (bind(state, host) !== ABI_VERSION) {
            fail("bind");
            return;
        }
    } catch (error) {
        fail("host api: " + (error instanceof Error ? error.message : String(error)));
        return;
    }

    stage("bound");
    const probe = () => {
        const call = new NativeFunction(module.hot_probe_stage, "int", ["pointer", "uint"]);
        for (const stage of [1, 2, 3, 4, 5, 6, 7]) {
            const status = call(state, stage);
            stageWrite("value", { stage: stage, status: status });
            if (status < 0) {
                result.status = status;
                result.stage = stage;
                result.ok = false;
                writeResult();
                return;
            }
        }
        const width = call(state, 7);
        result.status = width;
        result.screen_width = width > 0 ? width : null;
        result.ok = width > 0;
        writeResult();
    };

    const gameAssembly = Process.findModuleByName("GameAssembly.dll");
    stage("find", gameAssembly === null ? "null" : "present");
    if (gameAssembly !== null) {
        arm(gameAssembly, probe);
        return;
    }

    stage("observe");

    const observer = Process.attachModuleObserver({
        onAdded(added) {
            if (added.name.toLowerCase() === "gameassembly.dll") {
                observer.detach();
                arm(added, probe);
            }
        },
    });
}

function arm(mapped, probe) {
    stage("arm");
    try {
        const corlib = new NativeFunction(mapped.getExportByName("il2cpp_get_corlib"), "pointer", [])();
        stage("corlib", corlib.isNull());
        if (!corlib.isNull()) {
            probe();
            return;
        }
    } catch (_) {
        stage("corlib", "unready");
    }

    try {
        const init = mapped.getExportByName("il2cpp_init");
        Interceptor.attach(init, {
            onLeave() {
                setImmediate(() => {
                    stage("probe");
                    probe();
                });
            },
        });
        stage("hooked");
    } catch (error) {
        fail("il2cpp_init: " + (error instanceof Error ? error.message : String(error)));
    }
}

try {
    main();
} catch (error) {
    fail("main: " + (error instanceof Error ? error.message : String(error)));
}
