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

    const widthStatus = call("dev_selftest_width", "int", [])();
    report({ kind: "width-selftest", status: widthStatus });
    const virtualStatus = call("dev_selftest_virtual", "int", [])();
    report({ kind: "virtual-selftest", status: virtualStatus });
    const argsStatus = call("dev_selftest_args", "int", [])();
    report({ kind: "args-selftest", status: argsStatus });
    const selftest = widthStatus === 1 && argsStatus === 1 && virtualStatus === 1 ? 1 : -1;
    const before = call("dev_width_before", "int", [])();
    const after = call("dev_width_after", "int", [])();
    const final = call("dev_width_final", "int", [])();
    const count = call("dev_count", "uint", [])();
    const argCalls = call("dev_arg_calls", "uint", [])();
    const argSeen = call("dev_arg_seen", "float", [])();
    const argBefore = call("dev_arg_before", "float", [])();
    const argAfter = call("dev_arg_after", "float", [])();
    const argFinal = call("dev_arg_final", "float", [])();

    report({ kind: "details", selftest: selftest, before: before, after: after, final: final, count: count });
    report({ kind: "arguments", calls: argCalls, seen: argSeen, before: argBefore, after: argAfter, final: argFinal });

    const ok = selftest === 1 && before === after && after === final && count >= 1 && argCalls === 1 && argSeen === 0.5 && argAfter === 0.5;
    report({ kind: "result", ok: ok, selftest: selftest });

    const freeLibrary = new NativeFunction(kernel32.getExportByName("FreeLibrary"), "int", ["pointer"]);
    freeLibrary(module);
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
