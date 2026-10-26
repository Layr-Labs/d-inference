#!/usr/bin/env python3
"""Phase timeline of one provider start from its log.

Reads a `darkbloom start` / `darkbloom start --local` log (swift-log lines with
ISO-8601 timestamps) and reports each full weight read and load phase:
`WeightHasher` passes, the managed GLM load's verification and construction,
the shape warmup and the moment the server listened. `--started` supplies the
process start (for example `serve-info.txt`'s `started=`), so the first phase
is not hidden.

    python3 scripts/benchmarks/glm_load_timeline.py runs/LABEL/server.log \
        --started 2026-10-23T03:10:31Z [--json timeline.json]
"""

import argparse
import datetime as dt
import json
import re
import sys

STAMP = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d[+-]\d{4}) ")
HASH_START = re.compile(r"Computing weight hash for (\S+) \((\d+) files\)")
HASH_END = re.compile(r"Weight hash for (\S+): ([0-9a-f]{16})")
HASH_REUSED = re.compile(r"Weight hash for (\S+): ([0-9a-f]{16}) \(recorded by its last full verification")
GLM_LOAD = re.compile(
    r"GLM load (\S+): all (\d+) manifest files SHA-256 verified before serving; "
    r"auxiliary verification ([\d.]+) s, core verification ([\d.]+) s, "
    r"tensors and construction ([\d.]+) s, total ([\d.]+) s")
WARMUP = re.compile(r"Shape warmup (\S+): .* in (\d+) ms")
LISTENING = re.compile(r"(Server started and listening on|Startup preload gate: warm after)")


def parse_stamp(text):
    return dt.datetime.strptime(text, "%Y-%m-%dT%H:%M:%S%z")


def timeline(lines, started=None):
    """Return the ordered phases and summary counts of one start."""
    phases, open_hash, last = [], None, started
    reads = {"weight_hash_passes": 0, "weight_hash_reused": 0, "glm_verified_loads": 0}
    for line in lines:
        match = STAMP.match(line)
        if not match:
            continue
        at = parse_stamp(match.group(1))
        started = started or at
        if (m := HASH_REUSED.search(line)):
            reads["weight_hash_reused"] += 1
            phases.append({"phase": f"weight hash reused ({m.group(1)})", "at": at, "seconds": 0.0})
        elif (m := HASH_START.search(line)):
            open_hash = at
        elif (m := HASH_END.search(line)) and open_hash:
            reads["weight_hash_passes"] += 1
            phases.append({"phase": f"weight hash pass ({m.group(1)})", "at": open_hash,
                           "seconds": (at - open_hash).total_seconds()})
            open_hash = None
        elif (m := GLM_LOAD.search(line)):
            reads["glm_verified_loads"] += 1
            aux, core, build, total = (float(m.group(i)) for i in range(3, 7))
            begin = at - dt.timedelta(seconds=total)
            phases.append({"phase": "GLM auxiliary verification", "at": begin, "seconds": aux})
            phases.append({"phase": "GLM core SHA-256 verification", "at": begin, "seconds": core})
            phases.append({"phase": "GLM tensor reads and construction", "at": begin, "seconds": build})
        elif (m := WARMUP.search(line)):
            seconds = int(m.group(2)) / 1000
            phases.append({"phase": "shape warmup", "at": at - dt.timedelta(seconds=seconds),
                           "seconds": seconds})
        elif LISTENING.search(line):
            last = at
            phases.append({"phase": "listening", "at": at, "seconds": 0.0})
            break
    for phase in phases:
        phase["offset"] = (phase["at"] - started).total_seconds() if started else None
    return {
        "started": started.isoformat() if started else None,
        "ready_seconds": (last - started).total_seconds() if last and started else None,
        **reads,
        "phases": [
            {"phase": p["phase"], "offset_seconds": p["offset"], "seconds": p["seconds"]}
            for p in phases
        ],
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("log")
    parser.add_argument("--started", help="process start, ISO-8601 (e.g. 2026-10-23T03:10:31Z)")
    parser.add_argument("--json", help="also write the timeline here")
    args = parser.parse_args(argv)
    started = None
    if args.started:
        started = dt.datetime.fromisoformat(args.started.replace("Z", "+00:00"))
    with open(args.log, encoding="utf-8", errors="replace") as handle:
        result = timeline(handle, started)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
    print(f"{'offset s':>9}  {'seconds':>8}  phase")
    for phase in result["phases"]:
        offset = phase["offset_seconds"]
        print(f"{offset if offset is not None else float('nan'):9.1f}  {phase['seconds']:8.1f}  {phase['phase']}")
    print(f"ready after {result['ready_seconds']} s; full weight-hash passes: "
          f"{result['weight_hash_passes']}, reused: {result['weight_hash_reused']}, "
          f"verified GLM loads: {result['glm_verified_loads']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
