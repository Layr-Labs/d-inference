#!/usr/bin/env python3
"""Run independent check commands at the same time; report each one whole.

Reads one shell command per line from FILE (or standard input); blank lines
and lines starting with `#` are skipped. Up to --jobs commands run at once, in
the listed order, so list the longest first. Each runs under
`bash --noprofile --norc -eo pipefail -c` (as a workflow `run` step does) with
standard input closed and a private TMPDIR, so no two commands share a
temporary path.

Each command's output is printed whole, in the listed order, as soon as it and
every command before it have ended, with its exit status and duration. The
script exits 1 when any command fails, after every command has run; it never
retries a command and sets no time limit of its own.

Usage: run-concurrent-checks.py [--jobs N] [FILE]
"""

import argparse
import concurrent.futures
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time


SHELL = ("bash", "--noprofile", "--norc", "-eo", "pipefail", "-c")


def default_jobs():
    """The CPUs this process may use (a container's or runner's limit)."""
    if hasattr(os, "sched_getaffinity"):
        return len(os.sched_getaffinity(0))
    return os.cpu_count() or 1


def read_commands(lines):
    return [line.strip() for line in lines if line.strip() and not line.strip().startswith("#")]


class Checks:
    """The commands of one invocation, their processes while they run, and their results."""

    def __init__(self, commands, work):
        self.commands = commands
        self.work = work
        self.lock = threading.Lock()
        self.running = set()
        self.stopping = False

    def log(self, index):
        return self.work / f"{index:03d}.log"

    def run(self, index):
        """Run one command to its end; return (exit status, seconds)."""
        temporary = self.work / f"{index:03d}.tmp"
        temporary.mkdir()
        environment = {**os.environ, "TMPDIR": str(temporary)}
        started = time.monotonic()
        with open(self.log(index), "wb") as output:
            with self.lock:
                if self.stopping:
                    return None, 0.0
                try:
                    process = subprocess.Popen([*SHELL, self.commands[index]], stdin=subprocess.DEVNULL,
                                               stdout=output, stderr=subprocess.STDOUT, env=environment)
                except OSError as error:
                    output.write(f"Could not start: {error}\n".encode())
                    return 127, time.monotonic() - started
                self.running.add(process)
            try:
                status = process.wait()
            finally:
                with self.lock:
                    self.running.discard(process)
        return status, time.monotonic() - started

    def stop(self):
        """End the commands that are still running; start no more."""
        with self.lock:
            self.stopping = True
            for process in self.running:
                process.terminate()


def report(index, command, status, seconds, log, total):
    out = sys.stdout.buffer
    out.write(f"==> [{index + 1}/{total}] {command}\n".encode())
    out.write(log.read_bytes())
    verdict = "passed" if status == 0 else f"FAILED (exit {status})"
    out.write(f"<== [{index + 1}/{total}] {command}: {verdict} in {seconds:.1f} s\n\n".encode())
    out.flush()


def run_all(commands, jobs):
    """Run every command; return the list of (command, exit status, seconds)."""
    # A command may leave files it cannot delete; that is not a failed check.
    with tempfile.TemporaryDirectory(prefix="run-concurrent-checks-", ignore_cleanup_errors=True) as work:
        checks = Checks(commands, Path(work))
        # A cancelled job's runner sends SIGTERM: end the commands as well.
        previous = signal.signal(signal.SIGTERM, lambda number, frame: sys.exit(128 + number))
        executor = concurrent.futures.ThreadPoolExecutor(max_workers=jobs)
        try:
            futures = [executor.submit(checks.run, index) for index in range(len(commands))]
            results = []
            for index, future in enumerate(futures):
                status, seconds = future.result()
                report(index, commands[index], status, seconds, checks.log(index), len(commands))
                results.append((commands[index], status, seconds))
            return results
        finally:
            checks.stop()
            executor.shutdown(wait=True, cancel_futures=True)
            signal.signal(signal.SIGTERM, previous)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--jobs", type=int, default=default_jobs(),
                        help="commands at the same time (default: this process's CPUs)")
    parser.add_argument("file", nargs="?", type=argparse.FileType("r"), default=sys.stdin)
    args = parser.parse_args(argv)
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")
    commands = read_commands(args.file)
    if not commands:
        print("::error title=Checks::No command to run", flush=True)
        return 2
    started = time.monotonic()
    results = run_all(commands, args.jobs)
    failed = [(command, status, seconds) for command, status, seconds in results if status != 0]
    serial = sum(seconds for _, _, seconds in results)
    print(f"{len(results)} commands in {time.monotonic() - started:.1f} s, {args.jobs} at a time "
          f"({serial:.1f} s one after another): {len(results) - len(failed)} passed, {len(failed)} failed")
    for command, status, seconds in failed:
        print(f"::error title=Check failed::{command} exited {status} after {seconds:.1f} s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
