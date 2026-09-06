#!/usr/bin/env python3
"""Own one temporary localhost provider and benchmark it on a dedicated Mac.

No installation, daemon registration, shared cache writes, or foreign process
termination. Aborts its own process group if a ranked benchmark/CI job appears.
All generated configuration, logs, telemetry and local metadata use --output.
"""

import argparse
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time
import urllib.request


def ranked_job():
    return subprocess.run(["pgrep", "-f", r"Runner\.Worker|benchctl measure-job|measure-job\.sh"],
                          stdout=subprocess.DEVNULL).returncode == 0


def terminate(process):
    if process is None or process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGTERM)
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--model", default="EigenLabs/Qwen3.8-27B-4bit-mtp")
    parser.add_argument("--port", type=int, default=18120)
    parser.add_argument("--mtp", choices=["off", "on"], default="off")
    parser.add_argument("--cache", choices=["off", "on"], default="on")
    parser.add_argument("--kv-backend", choices=["auto", "paged", "contiguous"], default="auto")
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--lengths", default="512,2048,8192")
    parser.add_argument("--replay")
    args = parser.parse_args()
    if ranked_job() or subprocess.run(["pgrep", "-x", "darkbloom"], stdout=subprocess.DEVNULL).returncode == 0:
        raise SystemExit("Dedicated host is busy")
    if os.getloadavg()[0] > 4:
        raise SystemExit("Dedicated host load exceeds 4")
    # A clean serving startup must have nothing in the retired cache to sweep.
    if (Path.home() / "Library/Caches/darkbloom/kv").exists():
        raise SystemExit("Retired shared cache exists; use the direct engine harness")
    with socket.socket() as check:
        check.bind(("127.0.0.1", args.port))
    root = Path(args.output).resolve()
    root.mkdir(parents=True, exist_ok=False)
    macmon = Path.home() / "bench-runner/bin/macmon"
    raw = subprocess.check_output([str(macmon), "pipe", "-s", "1", "-i", "200"], text=True, timeout=10)
    temperature = json.loads(raw.splitlines()[0])["temp"]["gpu_temp_avg"]
    if temperature > 42:
        raise SystemExit(f"GPU entry temperature {temperature} exceeds 42 C")
    # Root must be new: never inherit another provider's PID or discovery record.
    env = os.environ.copy()
    selected_env = {
        "DARKBLOOM_NO_UPDATE_CHECK": "1", "DARKBLOOM_PID_FILE": str(root / "provider.pid"),
        "DARKBLOOM_LOCAL_DIR": str(root / "local"),
        "DARKBLOOM_PREFIX_CACHE": "1" if args.cache == "on" else "0",
        "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
        "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": str(root / "prefix-cache"),
        "DARKBLOOM_PREFIX_CACHE_STATS_INTERVAL_SECS": "1",
    }
    env.update(selected_env)
    config = root / "provider.toml"
    config.write_text(f'''config_version = 3
[backend]
enabled_models = [{json.dumps(args.model)}]
engine_v2_kv_backend = "{args.kv_backend}"
engine_v2_max_concurrent = 1
idle_timeout_mins = 60
max_model_slots = 1
mtp_mode = "{args.mtp}"
port = {args.port}
preload_models = []
startup_preload = false
startup_selftest = false
startup_selftest_fail_closed = false
[coordinator]
heartbeat_interval_secs = 30
private_only = true
url = "wss://127.0.0.1:1/ws/provider"
[provider]
auto_restart = false
auto_update = false
memory_reserve_gb = 2
name = "isolated-radix-benchmark"
''')
    metadata = {"started_unix": time.time(), "binary": str(Path(args.binary).resolve()),
                "environment": selected_env, "entry_gpu_temp_c": temperature, "arguments": vars(args)}
    server = client = telemetry = None
    try:
        with (root / "server.log").open("w") as server_log, (root / "telemetry.jsonl").open("w") as telemetry_log, (root / "client.log").open("w") as client_log:
            telemetry = subprocess.Popen([str(macmon), "pipe", "-i", "100"], stdout=telemetry_log,
                                         stderr=subprocess.DEVNULL, start_new_session=True)
            server = subprocess.Popen([args.binary, "start", "--local", "--config", str(config),
                                       "--model", args.model, "--port", str(args.port), "--no-auth"],
                                      env=env, stdout=server_log, stderr=subprocess.STDOUT, start_new_session=True)
            base = f"http://127.0.0.1:{args.port}"
            deadline = time.monotonic() + 180
            while True:
                if ranked_job():
                    raise RuntimeError("Ranked job appeared; abandoning owned benchmark")
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Provider did not become healthy; inspect server.log")
                try:
                    with urllib.request.urlopen(base + "/health", timeout=1):
                        break
                except OSError:
                    time.sleep(1)
            command = [sys.executable, str(Path(__file__).with_name("radix_prefix_cache.py")),
                       "--base", base, "--model", args.model, "--output", str(root / "http"),
                       "--label", root.name, "--repeats", str(args.repeats), "--lengths", args.lengths]
            if args.replay:
                command += ["--replay", args.replay]
            client = subprocess.Popen(command, stdout=client_log, stderr=subprocess.STDOUT, start_new_session=True)
            deadline = time.monotonic() + 1800
            while client.poll() is None:
                if ranked_job():
                    raise RuntimeError("Ranked job appeared; abandoning owned benchmark")
                if server.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Provider exited or bounded benchmark time exceeded")
                time.sleep(1)
            metadata["client_exit_code"] = client.returncode
            if client.returncode:
                raise RuntimeError("Benchmark failed; inspect client.log and retained evidence")
    finally:
        for process in (client, server, telemetry):
            terminate(process)
        metadata["ended_unix"] = time.time()
        metadata["ranked_job_at_end"] = ranked_job()
        (root / "metadata.json").write_text(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    # A disconnected controlling SSH session must reap only this run's children.
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))
    main()
