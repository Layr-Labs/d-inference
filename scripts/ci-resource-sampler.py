#!/usr/bin/env python3
"""Sample a macOS CI job's memory and CPU use and report the peaks. Report-only.

`start` runs the sampler in the background and gives later steps the samples
directory as CI_RESOURCE_SAMPLES. Every INTERVAL seconds it writes one CSV row:

- memory by class, from `vm_stat`: app (anonymous pages less purgeable ones;
  Metal buffers count here), wired, file cache (file-backed and purgeable
  pages, which the kernel can reclaim), compressed,
  and used = app + wired + compressed, as Activity Monitor counts it; swap in
  use (`sysctl vm.swapusage`) and the kernel's memory pressure level
  (`kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical);
- busy vCPUs over the interval, from the host's CPU ticks (`host_statistics`),
  or the sum of the `ps` %cpu averages where those are not available;
- the physical footprint of every process this user can read, from
  `proc_pid_rusage`: `ri_phys_footprint` is the counter `footprint` and
  Activity Monitor show, and it includes IOAccelerator (Metal) memory. The row
  keeps their sum and the three largest by lifetime peak
  (`ri_lifetime_max_phys_footprint`, so a peak between samples counts), each
  with the test selection it runs under;
- the largest resident process (`ps` RSS), to compare with earlier runs.

When the largest footprint first reaches 2 GiB, and again when it is 2 GiB
above the last capture, `/usr/bin/footprint`, where present, writes that
process's breakdown by category beside the samples (at most twice a job). Test
runners call `mark start|end LABEL PID` around each selection; a process below
PID belongs to LABEL.

`report` stops the sampler. It prints the peak of each class, the three
largest processes, the selections that ran at the peak, the busy vCPU mean,
95th percentile and maximum, and the sampled time scaled to 4 and 8 vCPUs; in
CI it also writes them to the step summary, and to summary.json beside the
samples. No subcommand ever fails a job: every error is printed and exits 0.

Subcommands:
  start DIRECTORY [--interval SECONDS]
  report DIRECTORY
  mark start|end LABEL [PID]   into $CI_RESOURCE_SAMPLES (nothing without it);
                               PID defaults to the caller, the mark's parent
  run DIRECTORY [--interval SECONDS]   the background loop `start` launches
"""

import argparse
import csv
import ctypes
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time


FIELDS = ("time", "used_bytes", "app_bytes", "wired_bytes", "file_bytes", "compressed_bytes", "swap_bytes",
          "pressure", "busy_vcpus", "footprint_bytes", "top_rss_bytes", "top_command", "top_footprints")
CLASSES = (("used_bytes", "Used"), ("app_bytes", "App"), ("wired_bytes", "Wired"),
           ("file_bytes", "File cache"), ("compressed_bytes", "Compressed"), ("swap_bytes", "Swap"))
SAMPLES = "samples.csv"
PID = "sampler.pid"
MACHINE = "machine.txt"
MARKS = "marks.csv"
SUMMARY = "summary.json"
ENVIRONMENT = "CI_RESOURCE_SAMPLES"
FOOTPRINT = "/usr/bin/footprint"
CAPTURES = 2
CAPTURE_STEP = 2 * 2**30
CAPTURE_SECONDS = 60
TOP = 3
SCALED_VCPUS = (4, 8)
GIB = 2**30
UNITS = {"K": 2**10, "M": 2**20, "G": 2**30}
RUSAGE_INFO_V4 = 4
HOST_CPU_LOAD_INFO = 3


class RusageInfoV4(ctypes.Structure):
    """struct rusage_info_v4 (<sys/resource.h>)."""
    _fields_ = [("ri_uuid", ctypes.c_uint8 * 16)] + [(name, ctypes.c_uint64) for name in (
        "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
        "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime", "ri_proc_exit_abstime",
        "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups", "ri_child_interrupt_wkups",
        "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread", "ri_diskio_byteswritten",
        "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance", "ri_cpu_time_qos_background",
        "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy", "ri_cpu_time_qos_user_initiated",
        "ri_cpu_time_qos_user_interactive", "ri_billed_system_time", "ri_serviced_system_time",
        "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions", "ri_cycles",
        "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint", "ri_runnable_time")]


# Native calls fail with these; the sampler then records what it can without them.
NATIVE_ERRORS = (OSError, AttributeError, TypeError, ctypes.ArgumentError)
_system = None


def system():
    """(libSystem with the calls the sampler makes, the host port); OSError where there is none."""
    global _system
    if _system is None:
        if sys.platform != "darwin":
            raise OSError("proc_pid_rusage and host_statistics need macOS")
        library = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
        library.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.POINTER(RusageInfoV4)]
        library.proc_pid_rusage.restype = ctypes.c_int
        library.mach_host_self.argtypes = []
        library.mach_host_self.restype = ctypes.c_uint32
        library.host_statistics.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.POINTER(ctypes.c_uint32 * 4),
                                            ctypes.POINTER(ctypes.c_uint32)]
        library.host_statistics.restype = ctypes.c_int
        _system = (library, library.mach_host_self())
    return _system


def output(*argv):
    return subprocess.run(argv, capture_output=True, text=True, timeout=10, check=True).stdout


def memory(vm_stat):
    """Bytes of each memory class (CLASSES but swap) from `vm_stat` text."""
    size = int(re.search(r"page size of (\d+) bytes", vm_stat).group(1))
    pages = {name.strip().lower(): int(value) for name, value in re.findall(r'^"?([^:"]+)"?:\s+(\d+)\.', vm_stat, re.M)}
    purgeable = pages["pages purgeable"]
    app = pages["anonymous pages"] - purgeable
    wired = pages["pages wired down"]
    compressed = pages["pages occupied by compressor"]
    return {"used_bytes": (app + wired + compressed) * size, "app_bytes": app * size, "wired_bytes": wired * size,
            "file_bytes": (pages["file-backed pages"] + purgeable) * size, "compressed_bytes": compressed * size}


def swap_used(swapusage):
    """Bytes of swap in use from `sysctl -n vm.swapusage` text."""
    match = re.search(r"used = ([0-9.]+)([KMG])", swapusage)
    return int(float(match.group(1)) * UNITS[match.group(2)])


def processes(ps):
    """[(pid, ppid, %cpu, RSS bytes, command)] from `ps -A -o pid=,ppid=,%cpu=,rss=,comm=` text."""
    rows = []
    for line in ps.splitlines():
        fields = line.split(None, 4)
        try:
            rows.append((int(fields[0]), int(fields[1]), float(fields[2]), int(fields[3]) * 1024,
                         os.path.basename(fields[4].strip()) if len(fields) > 4 else ""))
        except (IndexError, ValueError):
            continue
    return rows


def footprints(pids):
    """{pid: (physical footprint, lifetime peak)} of the processes this user can read."""
    library, _ = system()
    info = RusageInfoV4()
    found = {}
    for pid in pids:
        if library.proc_pid_rusage(pid, RUSAGE_INFO_V4, ctypes.byref(info)) == 0:
            found[pid] = (info.ri_phys_footprint, info.ri_lifetime_max_phys_footprint)
    return found


def cpu_ticks():
    """(busy, all) CPU ticks of every CPU since boot (HOST_CPU_LOAD_INFO: user, system, idle, nice)."""
    library, host = system()
    ticks = (ctypes.c_uint32 * 4)()
    count = ctypes.c_uint32(4)
    if library.host_statistics(host, HOST_CPU_LOAD_INFO, ctypes.byref(ticks), ctypes.byref(count)) != 0:
        raise OSError("host_statistics(HOST_CPU_LOAD_INFO) failed")
    return ticks[0] + ticks[1] + ticks[3], sum(ticks)


def busy_vcpus(before, after, cpus):
    """Busy vCPUs between two cpu_ticks() readings; None when no tick passed."""
    busy, total = ((now - then) % 2**32 for now, then in zip(after, before))
    return busy / total * cpus if total else None


def read_marks(path):
    """[(time, event, label, pid)] of the whole rows of a marks file; [] without one."""
    try:
        text = path.read_text()
    except OSError:
        return []
    marks = []
    for row in csv.reader(text.splitlines()):
        if len(row) != 4 or not row[3].isdigit():
            continue
        stamp, event, label, pid = row
        try:
            marks.append((float(stamp), event, label, int(pid)))
        except ValueError:
            continue
    return marks


def active_marks(path):
    """{pid: label} of the selections started under pid and not yet ended, from a marks file."""
    active = {}
    for _, event, label, pid in read_marks(path):
        if event == "start":
            active[pid] = label
        elif event == "end" and active.get(pid) == label:
            del active[pid]
    return active


def selection_of(pid, parents, active):
    """The label of the nearest marked ancestor of pid (itself included), or ""."""
    seen = set()
    while pid and pid not in seen:
        if pid in active:
            return active[pid]
        seen.add(pid)
        pid = parents.get(pid)
    return ""


class Sampler:
    """One sample a call; keeps the CPU ticks and footprint captures between calls."""

    def __init__(self, directory):
        self.directory = directory
        self.cpus = os.cpu_count() or 1
        self.ticks = self.read_ticks()
        self.captured_bytes = 0
        self.captures = []

    def read_ticks(self):
        try:
            return cpu_ticks()
        except NATIVE_ERRORS:
            return None

    def busy(self, listed):
        ticks = self.read_ticks()
        busy = busy_vcpus(self.ticks, ticks, self.cpus) if ticks and self.ticks else None
        self.ticks = ticks
        return sum(cpu for _, _, cpu, _, _ in listed) / 100 if busy is None else busy

    def sample(self):
        row = {"time": f"{time.time():.0f}", **memory(output("vm_stat"))}
        row["swap_bytes"] = swap_used(output("sysctl", "-n", "vm.swapusage"))
        row["pressure"] = output("sysctl", "-n", "kern.memorystatus_vm_pressure_level").strip()
        listed = processes(output("ps", "-A", "-o", "pid=,ppid=,%cpu=,rss=,comm="))
        row["busy_vcpus"] = f"{self.busy(listed):.2f}"
        largest = max(listed, key=lambda process: process[3], default=(0, 0, 0.0, 0, ""))
        row["top_rss_bytes"], row["top_command"] = largest[3], largest[4]
        try:
            found = footprints([pid for pid, *_ in listed])
        except NATIVE_ERRORS:
            found = {}
        if found:
            parents = {pid: ppid for pid, ppid, *_ in listed}
            commands = {pid: command for pid, _, _, _, command in listed}
            active = active_marks(self.directory / MARKS)
            ranked = sorted(found, key=lambda pid: found[pid][1], reverse=True)[:TOP]
            row["footprint_bytes"] = sum(current for current, _ in found.values())
            row["top_footprints"] = json.dumps([[pid, commands[pid], *found[pid], selection_of(pid, parents, active)]
                                                for pid in ranked])
            current = max(found, key=lambda pid: found[pid][0])
            self.capture(current, found[current][0], row["time"])
        self.reap()
        return [row.get(field, "") for field in FIELDS]

    def capture(self, pid, footprint, stamp):
        """`footprint PID` into the directory when footprint is CAPTURE_STEP above the last capture (or 0)."""
        if (footprint < self.captured_bytes + CAPTURE_STEP or len(self.captures) >= CAPTURES
                or not os.access(FOOTPRINT, os.X_OK)):
            return
        self.captured_bytes = footprint
        with open(self.directory / f"footprint-{stamp}-{pid}.txt", "w") as handle:
            self.captures.append((time.monotonic(), subprocess.Popen(
                [FOOTPRINT, str(pid)], stdin=subprocess.DEVNULL, stdout=handle, stderr=subprocess.STDOUT)))

    def reap(self):
        for started, child in self.captures:
            if child.poll() is None and time.monotonic() - started > CAPTURE_SECONDS:
                child.kill()


def run(directory, interval):
    sampler = Sampler(directory)
    with open(directory / SAMPLES, "a", newline="") as handle:
        writer = csv.writer(handle)
        while True:
            try:
                writer.writerow(sampler.sample())
                handle.flush()
            except Exception:  # Report-only: a failed sample is skipped; the loop goes on.
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
    github_env = os.environ.get("GITHUB_ENV")
    if github_env:
        with open(github_env, "a") as handle:
            handle.write(f"{ENVIRONMENT}={directory.resolve()}\n")
    print(f"Resource sampler: pid {child.pid}, every {interval} s, into {directory / SAMPLES}")


def mark(event, label, pid=None):
    """Note that selection `label` starts or ends under process pid (default: the caller); nothing
    outside a sampled job."""
    directory = os.environ.get(ENVIRONMENT)
    if not directory:
        return
    if event not in ("start", "end"):
        raise ValueError(f"mark takes start or end, got {event!r}")
    with open(Path(directory) / MARKS, "a", newline="") as handle:
        csv.writer(handle).writerow([f"{time.time():.3f}", event, label, os.getppid() if pid is None else int(pid)])


def percentile(values, fraction):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(fraction * len(ordered)))]


def number(value):
    return int(value) if value not in (None, "") else None


def gib(value):
    return "n/a" if value is None else f"{value / GIB:.2f}"


def utc(stamp):
    return time.strftime("%H:%M:%S", time.gmtime(float(stamp)))


def selections_at(path, moment):
    """The labels of the marks file that had started and not ended at moment."""
    spans = {}
    for stamp, event, label, pid in read_marks(path):
        span = spans.setdefault((label, pid), [None, None])
        span[0 if event == "start" else 1] = stamp
    return sorted(label for (label, _), (began, ended) in spans.items()
                  if began is not None and began <= moment and (ended is None or ended >= moment))


def scaled_seconds(rows, cpus):
    """Sampled seconds if busy vCPUs above `cpus` had run on `cpus`: each interval stretched by busy / cpus."""
    total = 0.0
    for before, after in zip(rows, rows[1:]):
        total += (int(after["time"]) - int(before["time"])) * max(1.0, float(after["busy_vcpus"]) / cpus)
    return total


def top_processes(rows):
    """The TOP processes by lifetime footprint peak: [pid, command, peak bytes, selection, time]."""
    best = {}
    for row in rows:
        for pid, command, _, peak, label in json.loads(row.get("top_footprints") or "[]"):
            known = best.get(pid)
            if known is None or peak > known[2]:
                best[pid] = [pid, command, peak, label or (known[3] if known else ""), row["time"]]
            elif label and not known[3]:
                known[3] = label
    return sorted(best.values(), key=lambda process: process[2], reverse=True)[:TOP]


def footprint_captures(directory):
    """[(file, its header and IOAccelerator lines)] of the `footprint` captures."""
    captured = []
    for path in sorted(directory.glob("footprint-*.txt")):
        lines = [line.strip() for line in path.read_text(errors="replace").splitlines() if line.strip()]
        kept = [line for line in lines if "Footprint" in line or "IOAccelerator" in line][:4] or lines[:1]
        captured.append((path.name, kept))
    return captured


def summary(directory):
    """The report's Markdown lines; also writes summary.json."""
    with open(directory / SAMPLES, newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        return ["Resource sampler: no samples."]
    facts = {"samples": len(rows), "seconds": int(rows[-1]["time"]) - int(rows[0]["time"]), "peaks": {}}
    lines = []
    machine = directory / MACHINE
    cpus = None
    if machine.is_file():
        cpus, memsize = (int(value) for value in machine.read_text().split())
        facts["machine"] = {"vcpus": cpus, "memory_bytes": memsize}
        lines.append(f"Machine: {cpus} vCPUs, {memsize / GIB:.1f} GiB.")
    for key, _ in CLASSES + (("footprint_bytes", "footprints"),):
        known = [row for row in rows if number(row.get(key)) is not None]
        peak = max(known, key=lambda row: number(row[key]), default=None)
        facts["peaks"][key] = None if peak is None else {"bytes": number(peak[key]), "time": int(peak["time"])}

    def peak_bytes(key):
        return None if facts["peaks"][key] is None else facts["peaks"][key]["bytes"]

    busy = [float(row["busy_vcpus"]) for row in rows]
    facts["pressure"] = max(int(row["pressure"]) for row in rows)
    facts["busy_vcpus"] = {"mean": sum(busy) / len(busy), "p95": percentile(busy, 0.95), "max": max(busy)}
    lines += [
        "| Samples | " + " | ".join(f"{name} (GiB)" for _, name in CLASSES) +
        " | Worst pressure | Busy vCPUs mean | p95 | max |",
        "|---" * (len(CLASSES) + 5) + "|",
        f"| {len(rows)} over {facts['seconds']} s | " + " | ".join(gib(peak_bytes(key)) for key, _ in CLASSES) +
        f" | {facts['pressure']} | {facts['busy_vcpus']['mean']:.2f} | {facts['busy_vcpus']['p95']:.2f} | "
        f"{facts['busy_vcpus']['max']:.2f} |",
        "",
        "Each class peaks at its own time. Used = app + wired + compressed (`vm_stat`); app holds Metal "
        "buffers; the file cache is reclaimable.",
    ]
    if facts["peaks"]["used_bytes"]:
        moment = facts["peaks"]["used_bytes"]["time"]
        running = selections_at(directory / MARKS, moment)
        facts["selections_at_peak_used"] = running
        lines.append(f"Peak used at {utc(moment)} UTC" + (f", during: {', '.join(running)}." if running else "."))
    top = top_processes(rows)
    facts["top_processes"] = [{"pid": pid, "command": command, "peak_footprint_bytes": footprint,
                               "selection": label, "time": int(stamp)} for pid, command, footprint, label, stamp in top]
    if top:
        lines += ["", "| Process | PID | Peak footprint (GiB) | Selection | Seen at (UTC) |", "|---|---|---|---|---|"]
        lines += [f"| `{command}` | {pid} | {gib(footprint)} | {label or '-'} | {utc(stamp)} |"
                  for pid, command, footprint, label, stamp in top]
        lines.append(f"Footprints: `proc_pid_rusage` lifetime peak (includes IOAccelerator/Metal memory), processes "
                     f"of this user only; their sum peaked at {gib(peak_bytes('footprint_bytes'))} GiB.")
    largest = max(rows, key=lambda row: int(row["top_rss_bytes"]))
    lines.append(f"Largest RSS (`ps`, earlier runs' figure): {gib(int(largest['top_rss_bytes']))} GiB "
                 f"(`{largest['top_command']}`).")
    if cpus:
        facts["scaled_seconds"] = {str(n): scaled_seconds(rows, n) for n in SCALED_VCPUS if n < cpus}
        if facts["scaled_seconds"]:
            lines.append(f"Sampled {facts['seconds']} s; at " +
                         ", at ".join(f"{n} vCPUs about {seconds:.0f} s" for n, seconds in facts["scaled_seconds"].items())
                         + " (each interval stretched by busy vCPUs / vCPUs where busy exceeds them).")
    captures = footprint_captures(directory)
    facts["footprint_tool"] = "present" if os.access(FOOTPRINT, os.X_OK) else "absent"
    facts["footprint_captures"] = [{"file": name, "lines": kept} for name, kept in captures]
    lines.append(f"`{FOOTPRINT}`: {facts['footprint_tool']}, {len(captures)} captures in the samples artifact.")
    lines += [f"- `{name}`: " + "; ".join(f"`{line}`" for line in kept) for name, kept in captures]
    (directory / SUMMARY).write_text(json.dumps(facts, indent=2, sort_keys=True) + "\n")
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
    marking = commands.add_parser("mark")
    marking.add_argument("event")
    marking.add_argument("label")
    marking.add_argument("pid", nargs="?")
    args = parser.parse_args(argv)
    try:
        if args.command == "start":
            start(args.directory, args.interval)
        elif args.command == "run":
            run(args.directory, args.interval)
        elif args.command == "mark":
            mark(args.event, args.label, args.pid)
        else:
            report(args.directory)
    except Exception as error:  # Report-only: never fail the job.
        print(f"::warning title=Resource sampler::{type(error).__name__}: {error}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
