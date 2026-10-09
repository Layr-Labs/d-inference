#!/usr/bin/env python3
"""Start an isolated ``darkbloom start --local`` server, run load against it, stop it.

Python standard library only; runs on the Mac that serves. One invocation is
one or more *sessions*. A session starts the provider with a task-owned home,
configuration, model cache, state files and prefix-cache root, waits until it
listens on loopback, runs the session's load (through loadgen.py), stops the
server with SIGTERM and waits for it to exit. Memory is recorded before the
start, once loaded, after the load and after the stop.

Isolation. The server is started with a scrubbed environment:

* ``CFFIXED_USER_HOME`` and ``HOME`` point at ``<work>/home``, so every default
  location the provider derives from the home directory (``~/.darkbloom``,
  ``~/.config/darkbloom``, ``~/Library/Caches``, ``~/.cache/huggingface``) is
  inside the work directory; the operator's own provider state is not read,
  written, drained or stopped.
* the state-path variables (PID file, state file, local endpoint directory,
  loaded-models file, watchdog state, auth token path, KV backend guard) point
  into ``<work>/run`` as a second guard, and the update check is off;
* the SSD prefix cache keeps its product default (on for the models that have
  it) but with an isolated root and an in-memory key
  (``DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL``/``..._TEST_ROOT``), the same way
  ``run_radix_http.py`` isolates it, so the keychain and Secure Enclave are
  never asked for a key;
* no ``MLX_*`` variable and no engine tuning variable is set.

The configuration file is written by the caller; it should name a coordinator
URL that cannot connect so that nothing in ``--local`` mode can reach one.

Stopping. The server is sent SIGTERM (its graceful drain) and then only waited
for. It is never sent SIGKILL: a process that holds a loaded model must release
it itself. If it has not exited after ``--stop-seconds`` the session is recorded
as failed, the script keeps waiting, and it says so once a minute.

The plan is a JSON file::

    {"sessions": [
      {"name": "p1024",
       "runs": [{"label": "cold-p1024", "args": ["--cell", "1024:128:1:1", "--warmup", "0"]},
                {"label": "warm-p1024", "args": ["--cell", "1024:128:1:10", "--warmup", "0"]}]}]}

Each run's ``args`` are passed to loadgen.py after the endpoint, model, output
directory, label, key file and calibration file.
"""

from __future__ import annotations

import argparse
import http.client
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import loadgen  # noqa: E402
import redact  # noqa: E402

TOKEN = re.compile(r"dk-local-[A-Za-z0-9_\-]+")
LITERALS = redact.local_literals()


def clean(text):
    return redact.redact(TOKEN.sub("dk-local-<redacted>", text), LITERALS)


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def output_of(arguments, timeout=30):
    try:
        return subprocess.run(arguments, capture_output=True, text=True, timeout=timeout).stdout
    except (OSError, subprocess.SubprocessError) as error:
        return f"unavailable: {error}"


def memory_snapshot(pid=None):
    """System memory from vm_stat (bytes) and, for a pid, its resident and footprint size."""
    snapshot = {"utc": utc()}
    text = output_of(["vm_stat"])
    page = re.search(r"page size of (\d+) bytes", text)
    page_size = int(page.group(1)) if page else 16384
    for name, key in (("Pages free", "free"), ("Pages active", "active"), ("Pages inactive", "inactive"),
                      ("Pages speculative", "speculative"), ("Pages wired down", "wired"),
                      ("Pages purgeable", "purgeable"), ("Pages occupied by compressor", "compressor")):
        match = re.search(rf"{name}:\s+(\d+)", text)
        if match:
            snapshot[f"{key}_bytes"] = int(match.group(1)) * page_size
    snapshot["swapusage"] = output_of(["sysctl", "-n", "vm.swapusage"]).strip()
    pressure = output_of(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
    snapshot["pressure_level"] = int(pressure) if pressure.isdigit() else pressure
    if pid is not None:
        fields = output_of(["ps", "-o", "rss=,vsz=", "-p", str(pid)]).split()
        if len(fields) == 2:
            snapshot["process_rss_bytes"] = int(fields[0]) * 1024
        footprint = output_of(["footprint", "-p", str(pid)], timeout=60)
        match = re.search(r"Footprint:\s*([\d.]+)\s*([KMGT]?B)", footprint) or \
            re.search(r"phys_footprint:\s*([\d.]+)\s*([KMGT]?B)", footprint)
        if match:
            scale = {"B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30, "TB": 1 << 40}[match.group(2)]
            snapshot["process_footprint_bytes"] = int(float(match.group(1)) * scale)
    return snapshot


def gib(value):
    return None if value is None else round(value / (1 << 30), 3)


class Server:
    def __init__(self, arguments, log_path):
        self.arguments, self.log_path = arguments, log_path
        self.process = None
        self.listening = threading.Event()
        self.lines = []

    def environment(self):
        work = self.arguments.work
        run = work / "run"
        for folder in (work / "home", work / "tmp", run, work / "local", work / "prefix-cache"):
            folder.mkdir(parents=True, exist_ok=True)
        return {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(work / "home"), "CFFIXED_USER_HOME": str(work / "home"), "TMPDIR": str(work / "tmp"),
            "DARKBLOOM_PID_FILE": str(run / "provider.pid"),
            "DARKBLOOM_STATE_FILE": str(run / "daemon-state.json"),
            "DARKBLOOM_LOCAL_DIR": str(work / "local"),
            "DARKBLOOM_LOADED_MODELS_FILE": str(run / "loaded-models.json"),
            "DARKBLOOM_WATCHDOG_STATE": str(run / "watchdog-state.json"),
            "DARKBLOOM_AUTH_TOKEN_PATH": str(run / "auth_token"),
            "DARKBLOOM_KV_BACKEND_GUARD": str(run / "kv-backend-guard.json"),
            "DARKBLOOM_NO_UPDATE_CHECK": "1",
            "DARKBLOOM_PREFIX_CACHE_ALLOW_EPHEMERAL": "1",
            "DARKBLOOM_PREFIX_CACHE_TEST_ROOT": str(work / "prefix-cache"),
        }

    def start(self):
        command = [str(self.arguments.binary), "start", "--local", "--model", self.arguments.model,
                   "--port", str(self.arguments.port), "--bind", "127.0.0.1",
                   "--config", str(self.arguments.config)]
        self.started = time.perf_counter()
        self.process = subprocess.Popen(command, env=self.environment(), cwd=str(self.arguments.work),
                                        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True, errors="replace")
        threading.Thread(target=self.pump, daemon=True).start()
        return command

    def pump(self):
        with open(self.log_path, "a", encoding="utf-8") as log:
            for line in self.process.stdout:
                stamped = f"[{utc()} +{time.perf_counter() - self.started:8.2f}s] {clean(line.rstrip())}"
                self.lines.append(stamped)
                log.write(stamped + "\n")
                log.flush()

    def wait_listening(self, seconds):
        """Ready means GET /health answers 200. The provider's own "Listening on" line is
        written to a pipe through a buffered stdout, so it cannot be used as the signal."""
        endpoint = loadgen.Endpoint(f"http://127.0.0.1:{self.arguments.port}")
        deadline = time.perf_counter() + seconds
        while time.perf_counter() < deadline:
            if self.process.poll() is not None:
                return False
            try:
                status, _ = endpoint.get("/health", timeout=2.0)
            except (OSError, http.client.HTTPException):
                status = None
            if status == 200:
                self.listening_after = time.perf_counter() - self.started
                self.listening.set()
                return True
            time.sleep(0.25)
        return False

    def stop(self, seconds, note):
        """SIGTERM, then wait. Never SIGKILL. Returns (exit status, seconds, clean)."""
        if self.process.poll() is not None:
            return self.process.returncode, 0.0, True
        began = time.perf_counter()
        self.process.send_signal(signal.SIGTERM)
        clean_exit = True
        while True:
            try:
                self.process.wait(timeout=60 if not clean_exit else seconds)
                break
            except subprocess.TimeoutExpired:
                clean_exit = False
                note(f"server pid {self.process.pid} still running "
                     f"{time.perf_counter() - began:.0f}s after SIGTERM; waiting (never SIGKILL)")
        return self.process.returncode, time.perf_counter() - began, clean_exit


def swap_used_mb():
    match = re.search(r"used = ([\d.]+)M", output_of(["sysctl", "-n", "vm.swapusage"]))
    return float(match.group(1)) if match else None


class PressureGuard(threading.Thread):
    """Stops the server (SIGTERM, graceful) if the Mac comes under memory pressure.

    For a model that needs most of the machine: the kernel's pressure level leaving
    "normal" (1), or swap growing by more than the allowance since the session began,
    ends the session before other work on the Mac is hurt. It never sends SIGKILL."""

    def __init__(self, server, allowance_mb, note):
        super().__init__(daemon=True)
        self.server, self.allowance_mb, self.note = server, allowance_mb, note
        self.baseline = swap_used_mb() or 0.0
        self.tripped = None
        self.done = threading.Event()

    def run(self):
        while not self.done.wait(2.0):
            level = output_of(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"]).strip()
            swap = swap_used_mb()
            reason = None
            if level.isdigit() and int(level) > 1:
                reason = f"memory pressure level {level}"
            elif swap is not None and swap - self.baseline > self.allowance_mb:
                reason = f"swap grew by {swap - self.baseline:.0f} MB"
            if reason and self.server.process and self.server.process.poll() is None:
                self.tripped = reason
                self.note(f"pressure guard: {reason}; stopping the server (SIGTERM)")
                self.server.process.send_signal(signal.SIGTERM)
                return


def leftover_processes(binary):
    """Serving processes of this binary (`<binary> start ...`); other commands of the
    same binary, such as a model download running beside the benchmark, do not count."""
    listing = output_of(["pgrep", "-fl", "--", re.escape(str(binary)) + " start "])
    return [clean(line) for line in listing.splitlines() if line.strip()]


def run_session(arguments, session, note):
    out = arguments.out
    name = session["name"]
    record = {"session": name, "started_utc": utc(), "model": arguments.model, "runs": [], "failures": [],
              "load_average_start": list(os.getloadavg()),
              "lanes_held": os.environ.get("WITH_LANE_HELD")}
    record["leftover_before"] = leftover_processes(arguments.binary)
    if record["leftover_before"]:
        record["failures"].append("a provider from this binary was already running; session not started")
        return record
    record["memory_before"] = memory_snapshot()
    server = Server(arguments, out / f"{name}.server.log")
    record["command"] = clean(" ".join(server.start()))
    stopping = threading.Event()
    guard = None
    if arguments.pressure_guard_swap_mb is not None:
        guard = PressureGuard(server, arguments.pressure_guard_swap_mb, note)
        guard.start()

    def on_signal(number, _frame):
        note(f"signal {number}: stopping the server")
        stopping.set()
        raise KeyboardInterrupt

    previous = {number: signal.signal(number, on_signal) for number in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT)}
    try:
        if not server.wait_listening(arguments.start_seconds):
            status = server.process.poll()
            record["failures"].append(
                f"server did not listen within {arguments.start_seconds}s"
                + (f"; it exited with status {status}" if status is not None else ""))
            record["server_log_tail"] = server.lines[-25:]
            return record
        record["listening_after_seconds"] = round(server.listening_after, 2)
        endpoint = loadgen.Endpoint(f"http://127.0.0.1:{arguments.port}")
        token_path = arguments.work / "local" / "local_token"
        key = token_path.read_text().strip() if token_path.exists() else None
        endpoint.api_key = key
        for path in ("/health", "/v1/models", "/props", "/metrics"):
            try:
                status, text = endpoint.get(path)
            except OSError as error:
                status, text = None, str(error)
            (out / f"{name}.server{path.replace('/', '-')}.txt").write_text(f"HTTP {status}\n{clean(text)}\n")
        record["memory_loaded"] = memory_snapshot(server.process.pid)
        for run in session.get("runs", []):
            label = run["label"]
            argv = ["--base-url", f"http://127.0.0.1:{arguments.port}", "--model", arguments.model,
                    "--output", str(out), "--label", label, "--calibration", str(arguments.calibration)]
            if key:
                argv += ["--api-key-file", str(token_path)]
            argv += [str(item) for item in run.get("args", [])]
            if run.get("sample_memory"):
                argv += ["--sample-every", str(run["sample_memory"]), "--sample-command",
                         f"vm_stat; sysctl -n vm.swapusage; ps -o rss= -p {server.process.pid}"]
            note(f"{name}: run {label} (load average {os.getloadavg()[0]:.1f})")
            record.setdefault("load_average_by_run", {})[label] = list(os.getloadavg())
            try:
                status = loadgen.main(argv)
            except SystemExit as error:
                status = error.code
            except KeyboardInterrupt:
                raise
            except Exception as error:  # a run that cannot proceed is a recorded failure, not a crash
                status = f"{type(error).__name__}: {error}"[:500]
                note(f"{name}: run {label} raised {status}")
            record["runs"].append({"label": label, "exit": status})
            if status not in (0, None):
                record["failures"].append(f"run {label} exited {status}")
            if server.process.poll() is not None:
                record["failures"].append(f"server exited with status {server.process.returncode} during {label}")
                break
        record["memory_after_load"] = memory_snapshot(server.process.pid if server.process.poll() is None else None)
        try:
            status, text = endpoint.get("/metrics")
            (out / f"{name}.server-metrics-end.txt").write_text(f"HTTP {status}\n{clean(text)}\n")
        except OSError:
            pass
    except KeyboardInterrupt:
        record["failures"].append("interrupted")
    finally:
        for number, handler in previous.items():
            signal.signal(number, handler)
        if guard:
            guard.done.set()
            if guard.tripped:
                record["failures"].append(f"stopped by the pressure guard: {guard.tripped}")
        status, seconds, clean_exit = server.stop(arguments.stop_seconds, note)
        record["server_exit_status"] = status
        record["stop_seconds"] = round(seconds, 2)
        if not clean_exit:
            record["failures"].append(f"server needed more than {arguments.stop_seconds}s to exit after SIGTERM")
        if status not in (0, -signal.SIGTERM, 128 + signal.SIGTERM):
            record["failures"].append(f"server exit status {status}")
        time.sleep(arguments.settle_seconds)
        record["memory_after_stop"] = memory_snapshot()
        record["leftover_after"] = leftover_processes(arguments.binary)
        if record["leftover_after"]:
            record["failures"].append("a provider process remained after the stop")
        record["server_log_tail"] = server.lines[-12:]
        record["finished_utc"] = utc()
        for key_name in ("memory_before", "memory_loaded", "memory_after_load", "memory_after_stop"):
            if key_name in record:
                record[key_name]["wired_gib"] = gib(record[key_name].get("wired_bytes"))
    if stopping.is_set():
        record["failures"].append("stopped by signal")
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--work", required=True, type=Path, help="task-owned work directory (home, cache, state)")
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--port", type=int, default=18200)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--plan", required=True, type=Path)
    parser.add_argument("--calibration", required=True, type=Path)
    parser.add_argument("--only", action="append", default=[], help="run only the named session (repeatable)")
    parser.add_argument("--start-seconds", type=float, default=600.0)
    parser.add_argument("--stop-seconds", type=float, default=300.0)
    parser.add_argument("--settle-seconds", type=float, default=5.0)
    parser.add_argument("--pressure-guard-swap-mb", type=float,
                        help="stop the server if memory pressure leaves normal or swap grows by more than this")
    arguments = parser.parse_args()
    for name in ("binary", "work", "config", "out", "plan", "calibration"):
        setattr(arguments, name, getattr(arguments, name).expanduser().resolve())
    arguments.out.mkdir(parents=True, exist_ok=True)

    def note(message):
        print(f"[{utc()}] {clean(message)}", file=sys.stderr, flush=True)

    plan = json.loads(arguments.plan.read_text())
    failures = 0
    for session in plan["sessions"]:
        if arguments.only and session["name"] not in arguments.only:
            continue
        report_path = arguments.out / f"{session['name']}.session.json"
        if report_path.exists():
            note(f"{session['name']}: report exists, skipping (reports are never overwritten)")
            continue
        note(f"{session['name']}: starting")
        record = run_session(arguments, session, note)
        report_path.write_text(json.dumps(record, indent=1, sort_keys=True) + "\n")
        failures += len(record["failures"])
        loaded = record.get("memory_loaded", {})
        note(f"{session['name']}: listening after {record.get('listening_after_seconds')}s; wired GiB before "
             f"{record.get('memory_before', {}).get('wired_gib')} loaded {loaded.get('wired_gib')} after stop "
             f"{record.get('memory_after_stop', {}).get('wired_gib')}; exit {record.get('server_exit_status')} "
             f"in {record.get('stop_seconds')}s; failures {record['failures']}")
        if "interrupted" in record["failures"] or "stopped by signal" in record["failures"]:
            break
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
