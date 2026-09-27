#!/usr/bin/env python3
"""Make the selected Xcode's Metal compiler executable within a bounded time.

Apple can finish downloading MetalToolchain before registering it for xcrun.
Keep the current Xcode/SDK selection, bypass negative lookup caches, and use
Apple's component export/import path when normal registration does not finish.
"""

import argparse
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


PROBE = ["xcrun", "--no-cache", "--sdk", "macosx", "metal", "--version"]
DOWNLOAD = ["xcodebuild", "-downloadComponent", "MetalToolchain"]


class SetupError(RuntimeError):
    pass


def exported_component(directory: Path) -> Path:
    candidates = [path for path in directory.iterdir()
                  if path.suffix in {".exportedBundle", ".dmg"}]
    if len(candidates) != 1:
        raise SetupError(f"Expected exactly one exported Metal component, found {len(candidates)}")
    candidate = candidates[0]
    expected_type = candidate.is_dir() if candidate.suffix == ".exportedBundle" else candidate.is_file()
    if candidate.is_symlink() or not expected_type:
        raise SetupError("Exported Metal component has an unsafe or unexpected file type")
    return candidate


class MetalSetup:
    def __init__(self, timeout=600.0, registration=45.0, poll=5.0, *,
                 run=subprocess.run, clock=time.monotonic, sleep=time.sleep,
                 log=print, temporary_root=None):
        if any(not math.isfinite(value) or value <= 0 for value in (timeout, registration, poll)):
            raise ValueError("Metal setup time limits must be finite positive numbers")
        self.run, self.clock, self.sleep, self.log = run, clock, sleep, log
        self.deadline = clock() + timeout
        self.registration, self.poll = registration, poll
        self.temporary_root = temporary_root
        self.last_probe_error = "compiler unavailable"

    def remaining(self):
        remaining = self.deadline - self.clock()
        if remaining <= 0:
            raise SetupError("Metal toolchain setup deadline exceeded")
        return remaining

    def invoke(self, arguments, limit=None):
        timeout = self.remaining()
        if limit is not None:
            timeout = min(timeout, limit)
        try:
            result = self.run(arguments, timeout=timeout, check=False,
                              capture_output=True, text=True)
        except subprocess.TimeoutExpired as error:
            raise SetupError(f"Metal setup command timed out: {' '.join(arguments)}") from error
        self.remaining()
        return result

    def checked(self, arguments):
        result = self.invoke(arguments)
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or "no diagnostics").strip()
            raise SetupError(f"Metal setup command failed ({result.returncode}): {detail}")
        if result.stdout.strip():
            self.log(result.stdout.strip())

    def probe(self, limit=30.0):
        result = self.invoke(PROBE, limit=limit)
        if result.returncode == 0:
            self.log(result.stdout.strip() or "Selected Xcode Metal compiler is ready")
            return True
        self.last_probe_error = (result.stderr or result.stdout or "compiler unavailable").strip()
        return False

    def wait_for_registration(self):
        until = min(self.deadline, self.clock() + self.registration)
        while self.clock() < until:
            if self.probe(limit=min(30.0, until - self.clock())):
                return True
            delay = min(self.poll, until - self.clock(), self.remaining())
            if delay > 0:
                self.sleep(delay)
        self.remaining()
        return False

    def prepare(self):
        if self.probe():
            # Downstream CMake uses ordinary xcrun lookups. The uncached probe
            # can succeed while their earlier negative lookup remains cached.
            self.checked(["xcrun", "--kill-cache"])
            return
        self.log("Downloading the selected Xcode Metal component")
        self.checked(DOWNLOAD)
        self.checked(["xcrun", "--kill-cache"])
        if self.wait_for_registration():
            return
        self.log("Metal registration is incomplete; exporting and importing the component")
        with tempfile.TemporaryDirectory(prefix="darkbloom-metal-", dir=self.temporary_root) as owned:
            export = Path(owned) / "export"
            export.mkdir()
            self.checked([*DOWNLOAD, "-exportPath", str(export)])
            component = exported_component(export)
            self.checked(["xcodebuild", "-importComponent", "MetalToolchain",
                          "-importPath", str(component)])
            self.checked(["xcrun", "--kill-cache"])
            if self.wait_for_registration():
                return
        raise SetupError("Metal compiler remains unavailable after component import: " + self.last_probe_error)


def positive_seconds(raw):
    value = float(raw)
    if not math.isfinite(value) or value <= 0:
        raise argparse.ArgumentTypeError("time limit must be a finite positive number")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--timeout-seconds", type=positive_seconds, default=600.0)
    parser.add_argument("--registration-seconds", type=positive_seconds, default=45.0)
    parser.add_argument("--poll-seconds", type=positive_seconds, default=5.0)
    args = parser.parse_args()
    try:
        MetalSetup(timeout=args.timeout_seconds, registration=args.registration_seconds,
                   poll=args.poll_seconds, temporary_root=os.environ.get("RUNNER_TEMP")).prepare()
    except (SetupError, OSError) as error:
        print(f"Metal toolchain setup failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
