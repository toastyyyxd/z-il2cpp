const DLL_PATH = "hooks/zil2cpp-hook-spike.dll";

function report(payload) {
    send(payload);
}

function runSpike() {
    const kernel32 = Process.getModuleByName("kernel32.dll");
    const loadLibrary = new NativeFunction(kernel32.getExportByName("LoadLibraryW"), "pointer", ["pointer"]);
    const getProcAddress = new NativeFunction(kernel32.getExportByName("GetProcAddress"), "pointer", ["pointer", "pointer"]);

    const module = loadLibrary(Memory.allocUtf16String(DLL_PATH));
    report({ kind: "loaded", module: module.toString() });
    if (module.isNull()) return report({ kind: "result", ok: false, stage: "load" });

    const install = new NativeFunction(getProcAddress(module, Memory.allocUtf8String("spike_install")), "int", []);
    const count = new NativeFunction(getProcAddress(module, Memory.allocUtf8String("spike_count")), "uint", []);
    const remove = new NativeFunction(getProcAddress(module, Memory.allocUtf8String("spike_remove")), "int", []);

    const installStatus = install();
    report({ kind: "install", status: installStatus });
    if (installStatus !== 1) return report({ kind: "result", ok: false, stage: "install", status: installStatus });

    const gameAssembly = Process.getModuleByName("GameAssembly.dll");
    const domainGet = new NativeFunction(gameAssembly.getExportByName("il2cpp_domain_get"), "pointer", []);
    domainGet();
    domainGet();
    const hookedCount = count();
    report({ kind: "calls", count: hookedCount });

    const removeStatus = remove();
    report({ kind: "remove", status: removeStatus });
    domainGet();
    const afterRemove = count();
    report({ kind: "after-remove", count: afterRemove, status: removeStatus });

    report({ kind: "result", ok: installStatus === 1 && hookedCount === 2 && afterRemove === 2, hooked: hookedCount, after_remove: afterRemove });
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
                runSpike();
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
