const ABI_VERSION = 1;
const INIT_MAGIC = 0x324c315a;
const STATE_SIZE = 64;
const STATE_TICK_COUNT_OFFSET = 16;

const result = {
    ok: false,
    frida: Frida.version,
    platform: Process.platform,
    arch: Process.arch,
    artifact: null,
};

function artifactPath() {
    if (Process.platform === "windows" && Process.arch === "x64") {
        return "hot/hot-windows-x86_64.pe";
    }
    if (Process.platform === "linux" && Process.arch === "x64") {
        return "hot/hot-linux-x86_64.so";
    }
    if (Process.platform === "linux" && Process.arch === "arm64") {
        return "hot/hot-linux-aarch64.so";
    }
    throw new Error("no bundled hot module for " + Process.platform + "/" + Process.arch);
}

function writeResult() {
    File.writeAllText("smoke-result.json", JSON.stringify(result, null, 2) + "\n");
    console.log("[hot-smoke] " + JSON.stringify(result));
}

function main() {
    try {
        const path = artifactPath();
        result.artifact = path;
        const bytes = File.readAllBytes(path);
        result.artifact_size = bytes.byteLength;

        const module = new CModule(bytes);
        globalThis.__hotModule = module;

        const required = [
            "hot_abi",
            "hot_state_size",
            "hot_init",
            "hot_tick",
            "hot_tick_count",
            "hot_last_frame",
        ];
        const missing = required.filter((name) => module[name] === undefined);
        if (missing.length !== 0) throw new Error("missing exports: " + missing.join(","));

        const abi = new NativeFunction(module.hot_abi, "uint", [])();
        const stateSize = new NativeFunction(module.hot_state_size, "uint", [])();
        result.abi = abi;
        result.state_size = stateSize;
        if (abi !== ABI_VERSION) throw new Error("ABI mismatch: module=" + abi);
        if (stateSize !== STATE_SIZE) throw new Error("state size mismatch: " + stateSize);

        const init = new NativeFunction(module.hot_init, "uint", ["pointer", "uint"]);
        const tick = new NativeFunction(module.hot_tick, "uint64", ["pointer", "uint64"]);
        const tickCount = new NativeFunction(module.hot_tick_count, "uint64", ["pointer"]);
        const lastFrame = new NativeFunction(module.hot_last_frame, "uint64", ["pointer"]);

        const rejected = Memory.alloc(stateSize);
        if (init(rejected, INIT_MAGIC ^ 0xffffffff) !== 0) throw new Error("hot_init accepted a bad magic");

        const state = Memory.alloc(stateSize);
        state.writeByteArray(new Uint8Array(stateSize).buffer);
        if (init(state, INIT_MAGIC) !== ABI_VERSION) throw new Error("hot_init rejected a good magic");

        result.state_abi = state.readU32();
        result.state_magic = state.add(4).readU32().toString(16);
        if (result.state_abi !== ABI_VERSION) throw new Error("state abi mismatch");
        if (state.add(4).readU32() !== INIT_MAGIC) throw new Error("state magic mismatch");

        if (init(ptr(0), INIT_MAGIC) !== 0) throw new Error("hot_init accepted null state");
        if (tick(ptr(0), 0).toNumber() !== 0) throw new Error("hot_tick accepted null state");

        const first = tick(state, 10).toNumber();
        const second = tick(state, 11).toNumber();
        const count = tickCount(state).toNumber();
        const frame = lastFrame(state).toNumber();
        result.ticks = [first, second];
        result.tick_count = count;
        result.last_frame = frame;
        if (first !== 1 || second !== 2) throw new Error("tick counter did not advance");
        if (count !== 2) throw new Error("tick_count mismatch: " + count);
        if (frame !== 11) throw new Error("last_frame mismatch: " + frame);
        if (state.add(STATE_TICK_COUNT_OFFSET).readU64().toNumber() !== 2) {
            throw new Error("state.tick_count was not written");
        }

        result.ok = true;
    } catch (error) {
        result.error = error instanceof Error ? error.message : String(error);
    }
    writeResult();
}

main();
