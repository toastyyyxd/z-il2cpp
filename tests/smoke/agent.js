const ABI_VERSION = 2;
const INIT_MAGIC = 0x324c315a;
const STATE_SIZE = 64;

const result = {
    ok: false,
    frida: Frida.version,
    platform: Process.platform,
    arch: Process.arch,
    artifact: null,
};

function artifactPath() {
    if (Process.platform === "windows" && Process.arch === "x64") return "shared/z-il2cpp-windows-x86_64.pe";
    if (Process.platform === "linux" && Process.arch === "x64") return "shared/z-il2cpp-linux-x86_64.so";
    if (Process.platform === "linux" && Process.arch === "arm64") return "shared/z-il2cpp-linux-aarch64.so";
    throw new Error("no shared artifact for " + Process.platform + "/" + Process.arch);
}

function writeResult() {
    File.writeAllText("smoke-result.json", JSON.stringify(result, null, 2) + "\n");
    console.log("[smoke] " + JSON.stringify(result));
}

function main() {
    try {
        const path = artifactPath();
        result.artifact = path;
        const bytes = File.readAllBytes(path);
        result.artifact_size = bytes.byteLength;
        const module = new CModule(bytes);
        globalThis.__sharedModule = module;

        const required = ["zil2cpp_abi", "zil2cpp_state_size", "zil2cpp_init", "zil2cpp_error_name", "zil2cpp_tick", "zil2cpp_tick_count", "zil2cpp_last_frame"];
        const missing = required.filter((name) => module[name] === undefined);
        if (missing.length !== 0) throw new Error("missing exports: " + missing.join(","));

        const abi = new NativeFunction(module.zil2cpp_abi, "uint", [])();
        const stateSize = new NativeFunction(module.zil2cpp_state_size, "uint", [])();
        result.abi = abi;
        result.state_size = stateSize;
        if (abi !== ABI_VERSION) throw new Error("ABI mismatch: " + abi);
        if (stateSize !== STATE_SIZE) throw new Error("state size mismatch: " + stateSize);

        const init = new NativeFunction(module.zil2cpp_init, "int", ["pointer", "uint"]);
        const tick = new NativeFunction(module.zil2cpp_tick, "uint64", ["pointer", "uint64"]);
        const tickCount = new NativeFunction(module.zil2cpp_tick_count, "uint64", ["pointer"]);
        const lastFrame = new NativeFunction(module.zil2cpp_last_frame, "uint64", ["pointer"]);

        const rejected = Memory.alloc(stateSize);
        if (init(rejected, INIT_MAGIC ^ 0xffffffff) !== -32) throw new Error("zil2cpp_init accepted a bad magic");

        const state = Memory.alloc(stateSize);
        state.writeByteArray(new Uint8Array(stateSize).buffer);
        if (init(state, INIT_MAGIC) !== ABI_VERSION) throw new Error("zil2cpp_init rejected a good magic");
        const errorName = new NativeFunction(module.zil2cpp_error_name, "pointer", ["int"]);
        const namePointer = errorName(-1);
        if (namePointer.isNull() || namePointer.readCString() !== "not initialized") throw new Error("zil2cpp_error_name mismatch");

        result.state_abi = state.readU32();
        result.state_magic = state.add(4).readU32().toString(16);
        if (result.state_abi !== ABI_VERSION) throw new Error("state abi mismatch");
        if (state.add(4).readU32() !== INIT_MAGIC) throw new Error("state magic mismatch");

        if (init(ptr(0), INIT_MAGIC) !== -32) throw new Error("zil2cpp_init accepted null state");
        if (tick(ptr(0), 0).toNumber() !== 0) throw new Error("zil2cpp_tick accepted null state");

        const first = tick(state, 10).toNumber();
        const second = tick(state, 11).toNumber();
        result.ticks = [first, second];
        result.tick_count = tickCount(state).toNumber();
        result.last_frame = lastFrame(state).toNumber();
        if (first !== 1 || second !== 2) throw new Error("tick counter did not advance");
        if (result.tick_count !== 2) throw new Error("tick_count mismatch: " + result.tick_count);
        if (result.last_frame !== 11) throw new Error("last_frame mismatch: " + result.last_frame);

        result.ok = true;
    } catch (error) {
        result.error = error instanceof Error ? error.message : String(error);
    }
    writeResult();
}

main();
