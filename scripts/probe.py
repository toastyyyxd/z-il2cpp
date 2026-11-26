#!/usr/bin/env python3
import argparse
import json
import sys
import time

import frida


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=27042)
    parser.add_argument("--script", default="tests/ingame/probe.js")
    parser.add_argument("--timeout", type=float, default=10.0)
    parser.add_argument("--set", action="append", default=[])
    args = parser.parse_args()

    source = open(args.script, "r", encoding="utf-8").read()
    for item in args.set:
        key, _, value = item.partition("=")
        source = f"const {key} = {json.dumps(value)};\n" + source
    device = frida.get_device_manager().add_remote_device(f"127.0.0.1:{args.port}")
    processes = device.enumerate_processes()
    if not processes:
        print("probe: no process", file=sys.stderr)
        return 1

    session = device.attach(processes[0].pid)
    state = {"ok": False, "done": False}

    def on_message(message, data):
        payload = message.get("payload")
        print(json.dumps(payload if payload is not None else message), flush=True)
        if isinstance(payload, dict) and payload.get("kind") == "result":
            state["ok"] = bool(payload.get("ok"))
            state["done"] = True

    script = session.create_script(source)
    script.on("message", on_message)
    script.load()

    deadline = time.time() + args.timeout
    while time.time() < deadline and not state["done"]:
        time.sleep(0.05)

    session.detach()
    return 0 if state["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
