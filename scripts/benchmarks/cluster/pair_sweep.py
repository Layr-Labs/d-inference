#!/usr/bin/env python3
"""Sweep the two-Mac pair driver over stage cuts, prefill schedules and prompt sizes.

Python standard library only. It drives the existing qualification tools
(``darkbloom-cluster-pair-check`` and ``darkbloom-cluster-reference``, see
libs/darkbloom-cluster-worker/README.md); it adds no runtime code. Rank 0 runs
on this Mac and rank 1 on the second Mac over SSH, exactly as the driver does.

The SSH destination, its options and the coordinator address come from the
environment (``PEER_SSH``, ``PEER_SSH_OPTIONS`` as space-separated ``Key=Value``
items, ``PAIR_COORDINATOR_IPV4``) so that no address is written into a file or
a report. Paths on the second Mac are given as arguments and appear only in
this process's command line.

Subcommands
-----------
preflight  Is the link ready on both Macs, and are the worker and metallib
           byte-identical on both? Exit 0 ready, 20 link not ready, 21 hashes
           differ, 22 a worker from this path is already running.
requests   Write one qualification request per prompt size (chat text, the
           fixed passage, thinking disabled, no stop tokens, so every run
           produces exactly ``--output-count`` tokens).
reference  Run the single-Mac staged reference for every request (this Mac).
sweep      For every prompt x cut x schedule: one recording run (final row
           kept; it is the discarded warm-up and the one the comparator can
           judge), then ``--repetitions`` serving runs (``--evidence none``),
           which are the timed ones. Resumable: an existing report is skipped.
           Stops with exit 75 when ``--budget-seconds`` would be exceeded, so a
           shared lane is not held too long; run it again to continue.
soak       Back-to-back serving sessions of one configuration for
           ``--seconds``; each session is one request (the driver's unit).
compare    Comparator verdict of every recording run against each reference.
summarize  Markdown tables from the reports.

Clocks. The driver reports ``firstTokenSeconds`` from its start command to rank
0's first committed token, and decode over the remaining tokens, both on the
driver's clock on this Mac; they include control and transport and exclude
loading. A pair "prefill tok/s" is prompt tokens divided by that first-token
time. Every pair run is the first and only request of a fresh session.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shlex
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import redact  # noqa: E402

ARITHMETIC = {"DARKBLOOM_CBV2_ATTN_QUERY_BLOCK": "128", "DARKBLOOM_BF16_WEIGHTS": "1", "MLX_ENABLE_TF32": "1"}
SCHEDULES = {"serial": "serial_v1", "lookahead": "one_chunk_lookahead_v1"}
LITERALS = redact.local_literals()


def utc():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def note(message):
    print(f"[{utc()}] {redact.redact(message, LITERALS)}", file=sys.stderr, flush=True)


def peer():
    destination = os.environ.get("PEER_SSH")
    if not destination:
        sys.exit("pair_sweep: set PEER_SSH to the SSH destination of the second Mac")
    return destination, os.environ.get("PEER_SSH_OPTIONS", "").split()


def remote(command, timeout=120):
    destination, options = peer()
    arguments = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
    for option in options:
        arguments += ["-o", option]
    return subprocess.run(arguments + [destination, command], capture_output=True, text=True, timeout=timeout)


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(8 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def preflight(arguments):
    report = {"utc": utc()}
    local = subprocess.run(shlex.split(arguments.local_link_command), capture_output=True, text=True, timeout=60)
    far = remote(arguments.remote_link_command)
    report["local_link"] = (local.stdout.splitlines() or ["(no output)"])[0]
    report["remote_link"] = (far.stdout.splitlines() or ["(no output)"])[0]
    ready = "Local link: ready" in report["local_link"] and "Local link: ready" in report["remote_link"]
    report["link_ready"] = ready
    worker, metallib = Path(arguments.local_worker), Path(arguments.local_worker).parent / "mlx.metallib"
    remote_metallib = str(Path(arguments.remote_worker).parent / "mlx.metallib")
    sums = remote(f"shasum -a 256 {shlex.quote(arguments.remote_worker)} {shlex.quote(remote_metallib)}").stdout.split()
    report["worker_sha256"] = {"local": sha256_file(worker), "remote": sums[0] if sums else None}
    report["metallib_sha256"] = {"local": sha256_file(metallib), "remote": sums[2] if len(sums) > 2 else None}
    report["hashes_identical"] = (report["worker_sha256"]["local"] == report["worker_sha256"]["remote"]
                                  and report["metallib_sha256"]["local"] == report["metallib_sha256"]["remote"])
    here = subprocess.run(["pgrep", "-f", str(worker)], capture_output=True, text=True).stdout.split()
    there = remote(f"pgrep -f {shlex.quote(arguments.remote_worker)[:-1]}[{arguments.remote_worker[-1]}] | wc -l").stdout.strip()
    report["workers_running"] = {"local": len(here), "remote": int(there) if there.isdigit() else None}
    print(json.dumps(report, indent=1, sort_keys=True))
    if not ready:
        return 20
    if not report["hashes_identical"]:
        return 21
    if report["workers_running"]["local"] or report["workers_running"]["remote"]:
        return 22
    return 0


def run_logged(command, stem, environment=None, timeout=900):
    """Run a tool, keep its stdout and stderr (scrubbed) beside its report."""
    started = time.perf_counter()
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=timeout,
                                env={**os.environ, **(environment or {})})
        status, out, err = result.returncode, result.stdout, result.stderr
    except subprocess.TimeoutExpired as error:
        status, out, err = 124, error.stdout or "", (error.stderr or "") + "\npair_sweep: timed out"
        if isinstance(out, bytes):
            out, err = out.decode("utf-8", "replace"), err if isinstance(err, str) else err.decode("utf-8", "replace")
    Path(str(stem) + ".stdout").write_text(redact.redact(out, LITERALS))
    Path(str(stem) + ".stderr").write_text(redact.redact(err, LITERALS))
    return status, time.perf_counter() - started


def requests(arguments):
    arguments.out.mkdir(parents=True, exist_ok=True)
    for size in arguments.prompts:
        path = arguments.out / f"request-p{size}.json"
        if path.exists():
            continue
        status, _ = run_logged([arguments.pair_check, "request", "--model-dir", arguments.local_model_dir,
                                "--user-text-file", arguments.text_file, "--prompt-tokens", str(size),
                                "--chunk-size", str(arguments.chunk_size), "--output-count",
                                str(arguments.output_count), "--output", str(path)],
                               arguments.out / f"request-p{size}")
        note(f"request p{size}: exit {status}")
        if status:
            return status
    return 0


def reference(arguments):
    failures = 0
    for size in arguments.prompts:
        path = arguments.out / f"reference-{arguments.role}-p{size}-cut{arguments.cut}.json"
        if path.exists():
            continue
        status, seconds = run_logged([arguments.reference_tool, "--model-dir", arguments.local_model_dir, "--request",
                                      str(arguments.out / f"request-p{size}.json"), "--stage-cut", str(arguments.cut),
                                      "--report", str(path)], str(path)[:-5], ARITHMETIC)
        note(f"reference {arguments.role} p{size} cut {arguments.cut}: exit {status} in {seconds:.0f}s")
        failures += status != 0
    return 1 if failures else 0


def pair_command(arguments, request, cut, schedule, report, evidence, port):
    destination, options = peer()
    address = os.environ.get("PAIR_COORDINATOR_IPV4")
    if not address:
        sys.exit("pair_sweep: set PAIR_COORDINATOR_IPV4 to rank 0's address on the link interface")
    command = [arguments.pair_check, "run", "--request", str(request), "--stage-cut", str(cut), "--report", str(report),
               "--remote-ssh", destination, "--local-worker", arguments.local_worker,
               "--remote-worker", arguments.remote_worker, "--local-model-dir", arguments.local_model_dir,
               "--remote-model-dir", arguments.remote_model_dir, "--local-rdma-device", arguments.local_rdma_device,
               "--remote-rdma-device", arguments.remote_rdma_device, "--coordinator", f"{address}:{port}",
               "--evidence", evidence, "--prefill-schedule", SCHEDULES[schedule],
               "--lifetime-seconds", str(arguments.lifetime_seconds),
               "--progress-timeout-ms", str(arguments.progress_timeout_ms)]
    for option in options:
        command += ["--ssh-option", option]
    if arguments.remote_scratch_dir:
        command += ["--remote-scratch-dir", arguments.remote_scratch_dir]
    if arguments.local_scratch_dir:
        command += ["--local-scratch-dir", arguments.local_scratch_dir]
    return command


def one_pair_run(arguments, name, request, cut, schedule, evidence, counter):
    report = arguments.out / f"{name}.json"
    if report.exists():
        return None
    port = arguments.base_port + (counter % 2000)
    status, seconds = run_logged(pair_command(arguments, request, cut, schedule, report, evidence, port),
                                 arguments.out / name, timeout=arguments.lifetime_seconds + 240)
    outcome = "no report"
    if report.exists():
        data = json.loads(report.read_text())
        outcome = data.get("outcome")
        left = sum(rank.get("workerProcessesLeft") or 0 for rank in data.get("ranks", []))
        if left:
            note(f"{name}: {left} worker process(es) LEFT BEHIND")
    note(f"{name}: exit {status} outcome {outcome} in {seconds:.0f}s")
    return status


def sweep(arguments):
    started = time.perf_counter()
    counter = int(time.time()) % 1000
    failures = 0
    for size in arguments.prompts:
        request = arguments.out / f"request-p{size}.json"
        for cut in arguments.cuts:
            for schedule in arguments.schedules:
                runs = [("recording", "final-row")] + [(f"serving-r{index + 1}", "none")
                                                       for index in range(arguments.repetitions)]
                for label, evidence in runs:
                    name = f"pair-p{size}-cut{cut}-{schedule}-{label}"
                    if (arguments.out / f"{name}.json").exists():
                        continue
                    if time.perf_counter() - started + arguments.per_run_estimate > arguments.budget_seconds:
                        note("budget reached; run again to continue")
                        return 75
                    counter += 1
                    status = one_pair_run(arguments, name, request, cut, schedule, evidence, counter)
                    failures += bool(status)
                    if status and arguments.stop_on_failure:
                        return 1
    return 1 if failures else 0


def soak(arguments):
    started = time.perf_counter()
    counter = int(time.time()) % 1000 + 1000
    index = failures = 0
    request = arguments.out / f"request-p{arguments.prompts[0]}.json"
    while time.perf_counter() - started + arguments.per_run_estimate < arguments.seconds:
        index += 1
        counter += 1
        name = f"soak-{arguments.tag}-{index:03d}"
        if (arguments.out / f"{name}.json").exists():
            continue
        status = one_pair_run(arguments, name, request, arguments.cuts[0], arguments.schedules[0], "none", counter)
        failures += bool(status)
        if failures >= arguments.max_failures:
            note("too many failures; stopping the soak")
            break
    return 1 if failures else 0


def compare(arguments):
    for recording in sorted(arguments.out.glob("pair-*-recording.json")):
        for candidate in sorted(arguments.out.glob("reference-*.json")):
            size = recording.name.split("-")[1]
            if f"-{size}-" not in candidate.name:
                continue
            target = arguments.out / f"compare-{candidate.stem}-vs-{recording.stem}.json"
            if target.exists():
                continue
            result = subprocess.run([arguments.pair_check, "compare", "--reference", str(candidate), "--candidate",
                                     str(recording), "--allow-cut-difference", "yes", "--allow-schedule-difference",
                                     "yes", "--json", "yes"], capture_output=True, text=True, timeout=300)
            target.write_text(redact.redact(result.stdout or json.dumps({"error": result.stderr[-2000:]}), LITERALS))
    return 0


def median(values):
    values = [value for value in values if value is not None]
    return statistics.median(values) if values else None


def cell(value, digits=1):
    return "—" if value is None else f"{value:,.{digits}f}"


def summarize(arguments):
    rows = {}
    for report in sorted(arguments.out.glob("pair-*.json")):
        data = json.loads(report.read_text())
        _, size, cut, schedule, label = report.stem.split("-", 4)
        key = (int(size[1:]), int(cut[3:]), schedule)
        entry = rows.setdefault(key, {"serving": [], "recording": None, "failed": 0, "left": 0, "wired": []})
        timing = data.get("timing") or {}
        if data.get("outcome") != "completed":
            entry["failed"] += 1
        entry["left"] += sum(rank.get("workerProcessesLeft") or 0 for rank in data.get("ranks", []))
        for rank in data.get("ranks", []):
            if rank.get("wiredBytesBefore") is not None and rank.get("wiredBytesAfter") is not None:
                entry["wired"].append((rank["wiredBytesAfter"] - rank["wiredBytesBefore"]) / (1 << 30))
        (entry["serving"].append(timing) if label.startswith("serving") else entry.__setitem__("recording", timing))
    verdicts = {}
    for path in arguments.out.glob("compare-*.json"):
        try:
            data = json.loads(path.read_text())
        except ValueError:
            continue
        reference_name, pair_name = path.stem[len("compare-"):].split("-vs-")
        _, size, cut, schedule, _ = pair_name.split("-", 4)
        role = reference_name.split("-")[1]
        verdicts.setdefault((int(size[1:]), int(cut[3:]), schedule), {})[role] = data.get("verdict", "?")
    print("| Prompt tok | Cut | Schedule | Serving runs ok | Prefill tok/s median (min–max) | First token s median | "
          "Decode tok/s median (min–max) | Ready s median | Recording-run prefill tok/s | Verdict vs each reference | "
          "Failed | Workers left | Max wired change GiB |")
    print("|---:|---:|---|---:|---:|---:|---:|---:|---:|---|---:|---:|---:|")
    for key in sorted(rows):
        entry = rows[key]
        serving = [timing for timing in entry["serving"] if timing.get("prefillTokensPerSecond")]
        prefill = [timing["prefillTokensPerSecond"] for timing in serving]
        decode = [timing["decodeTokensPerSecond"] for timing in serving if timing.get("decodeTokensPerSecond")]
        verdict = ", ".join(f"{role}: {value}" for role, value in sorted(verdicts.get(key, {}).items())) or "—"
        recording = (entry["recording"] or {}).get("prefillTokensPerSecond")
        print(f"| {key[0]:,} | {key[1]} | {key[2]} | {len(serving)}/{len(entry['serving'])} | "
              f"{cell(median(prefill), 0)} ({cell(min(prefill), 0) if prefill else '—'}–"
              f"{cell(max(prefill), 0) if prefill else '—'}) | "
              f"{cell(median([timing.get('firstTokenSeconds') for timing in serving]), 3)} | "
              f"{cell(median(decode))} ({cell(min(decode)) if decode else '—'}–{cell(max(decode)) if decode else '—'}) | "
              f"{cell(median([timing.get('startupSeconds') for timing in serving]))} | {cell(recording, 0)} | "
              f"{verdict} | {entry['failed']} | {entry['left']} | "
              f"{cell(max(entry['wired'], key=abs) if entry['wired'] else None, 2)} |")
    return 0


def integers(text):
    return [int(item) for item in text.split(",") if item]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["preflight", "requests", "reference", "sweep", "soak", "compare",
                                            "summarize"])
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--pair-check")
    parser.add_argument("--reference-tool")
    parser.add_argument("--local-worker")
    parser.add_argument("--remote-worker")
    parser.add_argument("--local-model-dir")
    parser.add_argument("--remote-model-dir")
    parser.add_argument("--local-rdma-device")
    parser.add_argument("--remote-rdma-device")
    parser.add_argument("--local-link-command", default="")
    parser.add_argument("--remote-link-command", default="")
    parser.add_argument("--local-scratch-dir", default="")
    parser.add_argument("--remote-scratch-dir", default="")
    parser.add_argument("--text-file", default=str(Path(__file__).resolve().parents[3]
                                                   / "libs/darkbloom-cluster-worker/Tests/QualificationPrompts/long-passage.txt"))
    parser.add_argument("--prompts", type=integers, default=[1024, 4096, 8192])
    parser.add_argument("--cuts", type=integers, default=[4, 8, 12, 16])
    parser.add_argument("--schedules", type=lambda text: text.split(","), default=["serial", "lookahead"])
    parser.add_argument("--output-count", type=int, default=128)
    parser.add_argument("--chunk-size", type=int, default=512)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--cut", type=int, default=4, help="reference: the cut to run the single-Mac reference at")
    parser.add_argument("--role", default="macA", help="reference: label of the Mac it ran on")
    parser.add_argument("--base-port", type=int, default=47100)
    parser.add_argument("--lifetime-seconds", type=int, default=120)
    parser.add_argument("--progress-timeout-ms", type=int, default=60000)
    parser.add_argument("--budget-seconds", type=float, default=1080.0)
    parser.add_argument("--per-run-estimate", type=float, default=40.0)
    parser.add_argument("--stop-on-failure", action="store_true")
    parser.add_argument("--seconds", type=float, default=600.0)
    parser.add_argument("--tag", default="a")
    parser.add_argument("--max-failures", type=int, default=3)
    arguments = parser.parse_args()
    arguments.out = arguments.out.resolve()
    arguments.out.mkdir(parents=True, exist_ok=True)
    return {"preflight": preflight, "requests": requests, "reference": reference, "sweep": sweep, "soak": soak,
            "compare": compare, "summarize": summarize}[arguments.command](arguments)


if __name__ == "__main__":
    sys.exit(main())
