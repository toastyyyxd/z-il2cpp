function report(payload) {
    send(payload);
}

function runTest() {
    const kernel32 = Process.getModuleByName("kernel32.dll");
    const loadLibrary = new NativeFunction(kernel32.getExportByName("LoadLibraryW"), "pointer", ["pointer"]);
    const getProcAddress = new NativeFunction(kernel32.getExportByName("GetProcAddress"), "pointer", ["pointer", "pointer"]);

    const module = loadLibrary(Memory.allocUtf16String("hooks/" + DLL_NAME));
    report({ kind: "loaded", module: module.toString(), dll: DLL_NAME });
    if (module.isNull()) return report({ kind: "result", ok: false, stage: "load" });

    const limit = typeof LIMIT === "number" ? LIMIT : parseInt(String(LIMIT ?? "16"), 10);
    const install = new NativeFunction(getProcAddress(module, Memory.allocUtf8String("dev_frame_install_limit")), "int", ["uint"]);
    const status = install(limit);
    if (typeof SKIP !== "undefined" && SKIP === "1") {
        const skip = new NativeFunction(getProcAddress(module, Memory.allocUtf8String("dev_frame_skip_original")), "void", ["uint"]);
        skip(1);
        report({ kind: "skip-original" });
    }
    report({ kind: "install", status: status });
    report({ kind: "result", ok: status === 1 });
}

function arm(mapped) {
    const listeners = [];
    let started = false;

    function install(address) {
        const listener = Interceptor.attach(address, {
            onEnter() {
                if (started) return;
                try {
                    const corlib = new NativeFunction(mapped.getExportByName("il2cpp_get_corlib"), "pointer", [])();
                    if (corlib.isNull()) return;
                } catch (_) {
                    return;
                }
                started = true;
                for (const other of listeners) other.detach();
                runTest();
            },
        });
        listeners.push(listener);
    }

    try {
        install(Process.getModuleByName("user32.dll").getExportByName("PeekMessageW"));
    } catch (_) {}
    report({ kind: "armed", hooks: listeners.length });
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

main();
