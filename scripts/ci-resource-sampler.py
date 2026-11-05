#!/usr/bin/env python3
"""Sample a macOS CI job's memory and CPU use and report the peaks. Report-only.

`start` runs the sampler in the background. Every INTERVAL seconds it writes
one CSV row: memory in use (active, wired and compressed pages, from
`vm_stat`), the compressed share, the kernel's memory pressure level
(`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical),
the CPU time of all processes in busy vCPUs and the largest resident process
(`ps`). `report` stops it and prints the peaks, the mean and 95th percentile
busy vCPUs, and the machine's vCPUs and memory (`sysctl`); in CI it also
writes them to the step summary. Neither subcommand ever fails a job: every
error is printed and exits 0.

Subcommands:
  start DIRECTORY [--interval SECONDS]
  report DIRECTORY
"""

import argparse
import csv
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


FIELDS = ("time", "used_bytes", "compressed_bytes", "pressure", "busy_vcpus", "top_rss_bytes", "top_command")
SAMPLES = "samples.csv"
PID = "sampler.pid"
MACHINE = "machine.txt"
GIB = 2**30


def output(*argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=10, check=True).stdout


def memory(vm_stat):
    """(bytes in use, compressed bytes) from `vm_stat` text."""
    size = int(re.search(r"page size of (\d+) bytes", vm_stat).group(1))
    pages = {name.strip().lower(): int(value) for name, value in re.findall(r'^"?([^:"]+)"?:\s+(\d+)\.', vm_stat, re.M)}
    compressed = pages["pages occupied by compressor"]
    return (pages["pages active"] + pages["pages wired down"] + compressed) * size, compressed * size


def processes(ps):
    """(busy vCPUs, largest RSS in bytes, its command) from `ps -A -o %cpu=,rss=,comm=` text."""
    busy, top, command = 0.0, 0, ""
    for line in ps.splitlines():
        fields = line.split(None, 2)
        if len(fields) < 2:
            continue
        busy += float(fields[0]) / 100
        rss = int(fields[1]) * 1024
        if rss > top:
            top, command = rss, os.path.basename(fields[2].strip()) if len(fields) > 2 else ""
    return busy, top, command


def sample():
    used, compressed = memory(output("vm_stat"))
    pressure = output("sysctl", "-n", "kern.memorystatus_vm_pressure_level").strip()
    busy, top, command = processes(output("ps", "-A", "-o", "%cpu=,rss=,comm="))
    return [f"{time.time():.0f}", used, compressed, pressure, f"{busy:.2f}", top, command]


def run(directory, interval):
    with open(directory / SAMPLES, "a", newline="") as handle:
        writer = csv.writer(handle)
        while True:
            try:
                writer.writerow(sample())
                handle.flush()
            except (OSError, ValueError, KeyError, AttributeError, subprocess.SubprocessError):
                pass
            time.sleep(interval)


def start(directory, interval):
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / SAMPLES, "w", newline="") as handle:
        csv.writer(handle).writerow(FIELDS)
    try:
        machine = output("sysctl", "-n", "hw.ncpu", "hw.memsize").split()
        (directory / MACHINE).write_text(f"{machine[0]} {machine[1]}\n")
    except (OSError, IndexError, subprocess.SubprocessError):
        pass
    child = subprocess.Popen([sys.executable, os.path.abspath(__file__), "run", str(directory), "--interval", str(interval)],
                             stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                             start_new_session=True)
    (directory / PID).write_text(f"{child.pid}\n")
    print(f"Resource sampler: pid {child.pid}, every {interval} s, into {directory / SAMPLES}")


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def summary(directory):
    """The report's Markdown lines."""
    with open(directory / SAMPLES, newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        return ["Resource sampler: no samples."]
    lines = []
    machine = directory / MACHINE
    if machine.is_file():
        cpus, memsize = machine.read_text().split()
        lines.append(f"Machine: {cpus} vCPUs, {int(memsize) / GIB:.1f} GiB.")
    used = max(rows, key=lambda row: int(row["used_bytes"]))
    top = max(rows, key=lambda row: int(row["top_rss_bytes"]))
    busy = [float(row["busy_vcpus"]) for row in rows]
    pressure = max(int(row["pressure"]) for row in rows)
    seconds = int(rows[-1]["time"]) - int(rows[0]["time"])
    lines += [
        f"| Samples | Peak memory in use (GiB) | Peak compressed (GiB) | Worst pressure level | "
        "Largest process RSS (GiB) | Busy vCPUs mean | Busy vCPUs p95 | Busy vCPUs max |",
        "|---|---|---|---|---|---|---|---|",
        f"| {len(rows)} over {seconds} s | {int(used['used_bytes']) / GIB:.2f} | "
        f"{max(int(row['compressed_bytes']) for row in rows) / GIB:.2f} | {pressure} | "
        f"{int(top['top_rss_bytes']) / GIB:.2f} (`{top['top_command']}`) | {sum(busy) / len(busy):.2f} | "
        f"{percentile(busy, 0.95):.2f} | {max(busy):.2f} |",
    ]
    return lines


def report(directory):
    pid = directory / PID
    if pid.is_file():
        try:
            os.kill(int(pid.read_text()), signal.SIGTERM)
        except (OSError, ValueError):
            pass
    lines = ["### Resource samples (report-only)", "", *summary(directory)]
    print("\n".join(lines))
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a") as handle:
            handle.write("\n".join(lines) + "\n\n")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("start", "run", "report"):
        command = commands.add_parser(name)
        command.add_argument("directory", type=Path)
        if name != "report":
            command.add_argument("--interval", type=float, default=5.0)
    args = parser.parse_args(argv)
    try:
        if args.command == "start":
            start(args.directory, args.interval)
        elif args.command == "run":
            run(args.directory, args.interval)
        else:
            report(args.directory)
    except Exception as error:  # Report-only: never fail the job.
        print(f"::warning title=Resource sampler::{type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
