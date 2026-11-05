#!/usr/bin/env python3
"""Offline checks of the report-only resource sampler: parsing, summary, never failing."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/ci-resource-sampler.py"
SPEC = importlib.util.spec_from_file_location("ci_resource_sampler", SCRIPT)
sampler = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sampler)

# macOS 27 `vm_stat` output, shortened.
VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100000.
Pages active:                             200000.
Pages inactive:                           150000.
Pages wired down:                          50000.
"Translation faults":                    9999999.
Pages occupied by compressor:              10000.
"""
PS = """  12.5  204800 /usr/bin/swift-frontend
 250.0 4194304 /private/tmp/dinf/provider-swift/.build/debug/ProviderPackageTests.xctest/Contents/MacOS/ProviderPackageTests
   0.0     512 bash
"""


class SamplerTests(unittest.TestCase):
    def test_memory_counts_active_wired_and_compressed_pages(self):
        used, compressed = sampler.memory(VM_STAT)
        self.assertEqual(used, (200000 + 50000 + 10000) * 16384)
        self.assertEqual(compressed, 10000 * 16384)
        with self.assertRaises(KeyError):
            sampler.memory(VM_STAT.replace("Pages wired down", "Pages wired"))

    def test_processes_sum_busy_vcpus_and_find_the_largest(self):
        busy, top, command = sampler.processes(PS + "\n  garbage\n")
        self.assertAlmostEqual(busy, 2.625)
        self.assertEqual(top, 4194304 * 1024)
        self.assertEqual(command, "ProviderPackageTests")

    def test_summary_reports_peaks_and_percentiles(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            rows = [",".join(sampler.FIELDS)]
            for second, (used, busy, pressure) in enumerate(((2, 1.0, 1), (6, 3.5, 2), (4, 0.5, 1))):
                rows.append(f"{100 + 5 * second},{used * sampler.GIB},{sampler.GIB // 2},{pressure},{busy},"
                            f"{used * sampler.GIB // 2},proc{second}")
            (directory / sampler.SAMPLES).write_text("\n".join(rows) + "\n")
            (directory / sampler.MACHINE).write_text(f"4 {16 * sampler.GIB}\n")
            lines = sampler.summary(directory)
        self.assertEqual(lines[0], "Machine: 4 vCPUs, 16.0 GiB.")
        self.assertEqual(lines[-1], "| 3 over 10 s | 6.00 | 0.50 | 2 | 3.00 (`proc1`) | 1.67 | 3.50 | 3.50 |")

    def test_report_never_fails_and_writes_the_step_summary(self):
        with tempfile.TemporaryDirectory() as work:
            summary = Path(work) / "summary"
            self.enterContext(mock.patch.dict(os.environ, {"GITHUB_STEP_SUMMARY": str(summary)}))
            printed = io.StringIO()
            with contextlib.redirect_stdout(printed):
                # No samples directory at all: a warning, never a failure.
                self.assertEqual(sampler.main(["report", str(Path(work) / "absent")]), 0)
            self.assertIn("::warning title=Resource sampler::", printed.getvalue())
            directory = Path(work) / "empty"
            directory.mkdir()
            (directory / sampler.SAMPLES).write_text(",".join(sampler.FIELDS) + "\n")
            (directory / sampler.PID).write_text("not a pid\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sampler.main(["report", str(directory)]), 0)
            self.assertIn("Resource sampler: no samples.", summary.read_text())

    def test_start_runs_in_the_background_until_report_stops_it(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work) / "samples"
            started = subprocess.run([sys.executable, str(SCRIPT), "start", str(directory), "--interval", "0.05"],
                                     capture_output=True, text=True, timeout=30)
            self.assertEqual(started.returncode, 0, started.stdout + started.stderr)
            pid = int((directory / sampler.PID).read_text())
            os.kill(pid, 0)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(sampler.main(["report", str(directory)]), 0)
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    break
                time.sleep(0.05)
            else:
                self.fail(f"sampler {pid} still runs after the report")


if __name__ == "__main__":
    unittest.main()
