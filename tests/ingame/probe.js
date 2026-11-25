const ABI_VERSION = 1;
const INIT_MAGIC = 0x324c315a;
const MODULE_PATH = "hot/hot-windows-x86_64.pe";

let hotModule = null;
let state = null;
let host = null;

function report(payload) {
    send(payload);
}

function fail(kind, error) {
    report({ kind: "result", ok: false, error: kind + ": " + String(error) });
}

function stageCall(stage) {
    const call = new NativeFunction(hotModule.hot_probe_stage, "int", ["pointer", "uint"]);
    const status = call(state, stage);
    report({ kind: "stage", stage: stage, status: status });
    return status;
}

function probeStages() {
    for (let stage = 0; stage <= 6; stage++) {
        if (stageCall(stage) < 0) {
            report({ kind: "result", ok: false, stage: stage });
            return;
        }
    }
    const width = stageCall(7);
    report({ kind: "result", ok: width > 0, screen_width: width, status: width });
}

function bind() {
    try {
        hotModule = new CModule(File.readAllBytes(MODULE_PATH));
        const required = ["hot_abi", "hot_state_size", "hot_init", "hot_bind_host", "hot_probe_stage"];
        const missing = required.filter((name) => hotModule[name] === undefined);
        if (missing.length !== 0) {
            fail("exports", missing.join(","));
            return false;
        }
        if (new NativeFunction(hotModule.hot_abi, "uint", [])() !== ABI_VERSION) {
            fail("abi", "mismatch");
            return false;
        }
        state = Memory.alloc(new NativeFunction(hotModule.hot_state_size, "uint", [])());
        const init = new NativeFunction(hotModule.hot_init, "uint", ["pointer", "uint"]);
        if (init(state, INIT_MAGIC) !== ABI_VERSION) {
            fail("init", "rejected");
            return false;
        }
        const kernel32 = Process.getModuleByName("kernel32.dll");
        host = Memory.alloc(Process.pointerSize * 2);
        host.writePointer(kernel32.getExportByName("GetModuleHandleW"));
        host.add(Process.pointerSize).writePointer(kernel32.getExportByName("GetProcAddress"));
        const binder = new NativeFunction(hotModule.hot_bind_host, "uint", ["pointer", "pointer"]);
        if (binder(state, host) !== ABI_VERSION) {
            fail("bind", "rejected");
            return false;
        }
        return true;
    } catch (error) {
        fail("bind", error instanceof Error ? error.message : String(error));
        return false;
    }
}

function arm(mapped) {
    try {
        const corlib = new NativeFunction(mapped.getExportByName("il2cpp_get_corlib"), "pointer", [])();
        if (!corlib.isNull()) {
            probeStages();
            return;
        }
    } catch (_) {
        report({ kind: "state", value: "runtime not initialized" });
    }

    const readiness = stageCall(0);
    if (readiness === 1) {
        probeStages();
        return;
    }
    report({ kind: "readiness", status: readiness });

    try {
        const init = mapped.getExportByName("il2cpp_init");
        Interceptor.attach(init, {
            onLeave() {
                setImmediate(probeStages);
            },
        });
        report({ kind: "armed" });
    } catch (error) {
        fail("hook", error instanceof Error ? error.message : String(error));
    }
}

function main() {
    if (!bind()) return;
    const mapped = Process.findModuleByName("GameAssembly.dll");
    if (mapped !== null) {
        arm(mapped);
        return;
    }
    const observer = Process.attachModuleObserver({
        onAdded(added) {
            if (added.name.toLowerCase() === "gameassembly.dll") {
                observer.detach();
                arm(added);
            }
        },
    });
    report({ kind: "waiting" });
}

main();
