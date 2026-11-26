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

    const call = (name, returnType, argumentTypes) => new NativeFunction(getProcAddress(module, Memory.allocUtf8String(name)), returnType, argumentTypes);

    const selftest = call("dev_selftest", "int", [])();
    const before = call("dev_width_before", "int", [])();
    const after = call("dev_width_after", "int", [])();
    const final = call("dev_width_final", "int", [])();
    const count = call("dev_count", "uint", [])();
    const offset = call("dev_offset", "size_t", [])();

    report({ kind: "details", selftest: selftest, before: before, after: after, final: final, count: count, offset: offset.toString() });

    const ok = selftest === 1 && before === after && after === final && count === 2;
    report({ kind: "result", ok: ok, selftest: selftest });
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
        install(mapped.getExportByName("il2cpp_object_new"));
    } catch (_) {}
    try {
        install(mapped.getExportByName("il2cpp_string_new"));
    } catch (_) {}
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
