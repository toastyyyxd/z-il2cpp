const ABI_VERSION = 1;
const INIT_MAGIC = 0x324c315a;
const MODULE_PATH = "shared/z-il2cpp-windows-x86_64.pe";
const SCRATCH_SIZE = 4096;

const result = {
    ok: false,
    frida: Frida.version,
    module: MODULE_PATH,
    screen_width: null,
    status: null,
};

let libraryModule = null;
let state = null;
let loader = null;
let scratch = null;

function writeResult() {
    File.writeAllText("probe-result.json", JSON.stringify(result, null, 2) + "\n");
    console.log("[probe] " + JSON.stringify(result));
}

function fail(kind, error) {
    result.error = kind + ": " + String(error);
    writeResult();
}

function bind() {
    try {
        libraryModule = new CModule(File.readAllBytes(MODULE_PATH));
        const required = ["zil2cpp_abi", "zil2cpp_state_size", "zil2cpp_init", "zil2cpp_runtime_init", "zil2cpp_probe_screen_width"];
        const missing = required.filter((name) => libraryModule[name] === undefined);
        if (missing.length !== 0) return fail("exports", missing.join(",")), false;
        if (new NativeFunction(libraryModule.zil2cpp_abi, "uint", [])() !== ABI_VERSION) return fail("abi", "mismatch"), false;
        state = Memory.alloc(new NativeFunction(libraryModule.zil2cpp_state_size, "uint", [])());
        const init = new NativeFunction(libraryModule.zil2cpp_init, "uint", ["pointer", "uint"]);
        if (init(state, INIT_MAGIC) !== ABI_VERSION) return fail("init", "rejected"), false;
        const kernel32 = Process.getModuleByName("kernel32.dll");
        loader = Memory.alloc(Process.pointerSize * 2);
        loader.writePointer(kernel32.getExportByName("GetModuleHandleW"));
        loader.add(Process.pointerSize).writePointer(kernel32.getExportByName("GetProcAddress"));
        scratch = Memory.alloc(SCRATCH_SIZE);
        const runtimeInit = new NativeFunction(libraryModule.zil2cpp_runtime_init, "int", ["pointer", "pointer", "pointer", "size_t"]);
        const status = runtimeInit(state, loader, scratch, SCRATCH_SIZE);
        if (status !== ABI_VERSION) return fail("runtime_init", status), false;
        return true;
    } catch (error) {
        return fail("bind", error instanceof Error ? error.message : String(error)), false;
    }
}

function run() {
    if (!bind()) return;
    const width = new NativeFunction(libraryModule.zil2cpp_probe_screen_width, "int", ["pointer"])(state);
    result.status = width;
    result.screen_width = width > 0 ? width : null;
    result.ok = width > 0;
    writeResult();
}

function arm(mapped) {
    try {
        const corlib = new NativeFunction(mapped.getExportByName("il2cpp_get_corlib"), "pointer", [])();
        if (!corlib.isNull()) {
            run();
            return;
        }
    } catch (_) {
    }

    try {
        const init = mapped.getExportByName("il2cpp_init");
        Interceptor.attach(init, {
            onLeave() {
                // IL2CPP calls from the JS thread crash during startup. Run on a game thread.
                const objectNew = mapped.getExportByName("il2cpp_object_new");
                const allocation = Interceptor.attach(objectNew, {
                    onEnter() {
                        allocation.detach();
                        run();
                    },
                });
            },
        });
    } catch (error) {
        fail("hook", error instanceof Error ? error.message : String(error));
    }
}

function main() {
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
}

try {
    main();
} catch (error) {
    fail("main", error instanceof Error ? error.message : String(error));
}
