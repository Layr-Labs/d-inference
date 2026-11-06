#!/usr/bin/env python3
"""Offline checks of the report-only resource sampler: parsing, attribution, summary, never failing.

The native readers (`proc_pid_rusage`, `host_statistics`) and a whole sample
run only on macOS; the CI jobs' own samples are their check.
"""

import contextlib
import csv
import importlib.util
import io
import json
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
GIB = sampler.GIB

# macOS 27 `vm_stat` output, shortened.
VM_STAT = """Mach Virtual Memory Statistics: (page size of 16384 bytes)
Pages free:                               100000.
Pages active:                             200000.
Pages inactive:                           150000.
Pages speculative:                          5000.
Pages wired down:                          50000.
Pages purgeable:                            2000.
"Translation faults":                    9999999.
File-backed pages:                        120000.
Anonymous pages:                          230000.
Pages occupied by compressor:              10000.
"""
PS = """    1     0   0.0     512 /sbin/launchd
  100     1  12.5  204800 /usr/bin/swift-frontend
  200   150 250.0 4194304 /private/tmp/dinf/provider-swift/.build/debug/swiftpm-testing-helper
  150     1   0.0     512 /Applications/Xcode 27.app/usr/bin/my tool
  garbage
"""
FOOTPRINT_TEXT = """======================================================================
swiftpm-testing-helper [200]: 64-bit    Footprint: 9 GB (16384 bytes per page)
======================================================================

    Dirty      Clean  Reclaimable    Regions    Category
     6 GB        0 B          0 B         12    IOAccelerator (graphics)
     1 GB        0 B          0 B        800    MALLOC_LARGE
"""


def write_rows(directory, rows):
    with open(directory / sampler.SAMPLES, "w", newline="") as handle:
        writer = csv.DictWriter(handle, sampler.FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def row(stamp, used, app, wired, cache, compressed, swap, pressure, busy, footprint, top):
    return {"time": stamp, "used_bytes": used * GIB, "app_bytes": app * GIB, "wired_bytes": wired * GIB,
            "file_bytes": cache * GIB, "compressed_bytes": compressed * GIB, "swap_bytes": swap * GIB,
            "pressure": pressure, "busy_vcpus": busy, "footprint_bytes": "" if footprint is None else footprint * GIB,
            "top_rss_bytes": GIB, "top_command": "swiftpm-testing-helper",
            "top_footprints": json.dumps(top) if top else ""}


class ParsingTests(unittest.TestCase):
    def test_memory_counts_each_class_as_activity_monitor_does(self):
        classes = sampler.memory(VM_STAT)
        page = 16384
        self.assertEqual(classes, {
            "used_bytes": (228000 + 50000 + 10000) * page, "app_bytes": 228000 * page,
            "wired_bytes": 50000 * page, "file_bytes": 122000 * page, "compressed_bytes": 10000 * page})
        with self.assertRaises(KeyError):
            sampler.memory(VM_STAT.replace("Anonymous pages", "Anonymous"))

    def test_swap_used_reads_each_unit(self):
        self.assertEqual(sampler.swap_used("total = 2048.00M  used = 1536.50M  free = 511.50M  (encrypted)"),
                         int(1536.5 * 2**20))
        self.assertEqual(sampler.swap_used("total = 4.00G  used = 1.50G  free = 2.50G"), int(1.5 * GIB))
        self.assertEqual(sampler.swap_used("total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)"), 0)
        with self.assertRaises(AttributeError):
            sampler.swap_used("no swap")

    def test_processes_keep_pid_parent_cpu_rss_and_the_command_name(self):
        listed = sampler.processes(PS)
        self.assertEqual(listed[1], (100, 1, 12.5, 204800 * 1024, "swift-frontend"))
        self.assertEqual(listed[2][4], "swiftpm-testing-helper")
        self.assertEqual(listed[3][4], "my tool")
        self.assertEqual(len(listed), 4)

    def test_busy_vcpus_from_tick_deltas_survive_a_counter_wrap(self):
        self.assertAlmostEqual(sampler.busy_vcpus((100, 1000), (400, 1600), 12), 6.0)
        self.assertAlmostEqual(sampler.busy_vcpus((2**32 - 100, 2**32 - 50), (200, 550), 12), 6.0)
        self.assertIsNone(sampler.busy_vcpus((5, 9), (5, 9), 12))

    def test_native_readers_refuse_outside_macos(self):
        if sys.platform == "darwin":
            self.skipTest("the native readers exist here")
        with self.assertRaises(OSError):
            sampler.footprints([1])
        self.assertIsNone(sampler.Sampler(Path(".")).read_ticks())


class AttributionTests(unittest.TestCase):
    def test_active_marks_and_the_nearest_marked_ancestor_name_the_selection(self):
        with tempfile.TemporaryDirectory() as work:
            marks = Path(work) / sampler.MARKS
            self.assertEqual(sampler.active_marks(marks), {})
            marks.write_text("1.0,start,1-of-6,150\n2.0,start,2-of-6,160\n3.0,end,1-of-6,150\n"
                             "4.0,start,parallel,150\n5.0,end,1-of-6,160\nbroken\n6.0,start,x,pid\n7.0,start,y,1.5\n"
                             "partial,start,z,170\n")
            active = sampler.active_marks(marks)
        # An end ends only the same label under the same pid; a row with a bad time or pid is skipped.
        self.assertEqual(active, {150: "parallel", 160: "2-of-6"})
        parents = {300: 200, 200: 160, 160: 1, 1: 0, 7: 8, 8: 7}
        self.assertEqual(sampler.selection_of(300, parents, active), "2-of-6")
        self.assertEqual(sampler.selection_of(150, parents, active), "parallel")
        self.assertEqual(sampler.selection_of(999, parents, active), "")
        self.assertEqual(sampler.selection_of(7, parents, active), "")

    def test_mark_writes_only_in_a_sampled_job_and_defaults_to_its_caller(self):
        with tempfile.TemporaryDirectory() as work:
            with mock.patch.dict(os.environ, {}, clear=False):
                os.environ.pop(sampler.ENVIRONMENT, None)
                sampler.mark("start", "1-of-6")
            self.assertFalse((Path(work) / sampler.MARKS).exists())
            with mock.patch.dict(os.environ, {sampler.ENVIRONMENT: work}):
                sampler.mark("start", "1-of-6")
                sampler.mark("end", "1-of-6", 4242)
                with self.assertRaises(ValueError):
                    sampler.mark("begin", "1-of-6", 1)
                printed = io.StringIO()
                with contextlib.redirect_stdout(printed):
                    self.assertEqual(sampler.main(["mark", "begin", "1-of-6"]), 0)
                self.assertIn("::warning title=Resource sampler::ValueError", printed.getvalue())
            rows = list(csv.reader((Path(work) / sampler.MARKS).read_text().splitlines()))
        self.assertEqual([row[1:] for row in rows], [["start", "1-of-6", str(os.getppid())],
                                                     ["end", "1-of-6", "4242"]])


class CaptureTests(unittest.TestCase):
    def test_footprint_runs_on_each_new_high_and_at_most_twice(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            self.enterContext(mock.patch.object(sampler, "FOOTPRINT", "/bin/echo"))
            capturing = sampler.Sampler(directory)
            capturing.capture(200, GIB, "100")  # Under the first step.
            capturing.capture(200, 3 * GIB, "105")
            capturing.capture(200, 4 * GIB, "110")  # Not 2 GiB above the last capture.
            capturing.capture(201, 5 * GIB, "115")
            capturing.capture(202, 9 * GIB, "120")  # Two captures already.
            for _, child in capturing.captures:
                child.wait(timeout=10)
            self.assertEqual(sorted(path.name for path in directory.glob("footprint-*")),
                             ["footprint-105-200.txt", "footprint-115-201.txt"])
            self.assertEqual((directory / "footprint-115-201.txt").read_text(), "201\n")

    def test_a_footprint_that_outlives_its_time_is_killed(self):
        with tempfile.TemporaryDirectory() as work:
            self.enterContext(mock.patch.object(sampler, "FOOTPRINT", "/bin/sleep"))
            self.enterContext(mock.patch.object(sampler, "CAPTURE_SECONDS", -1))
            capturing = sampler.Sampler(Path(work))
            capturing.capture(30, 3 * GIB, "100")
            capturing.reap()
            _, child = capturing.captures[0]
            self.assertLess(child.wait(timeout=10), 0)

    def test_no_capture_without_the_tool(self):
        with tempfile.TemporaryDirectory() as work:
            self.enterContext(mock.patch.object(sampler, "FOOTPRINT", str(Path(work) / "absent")))
            capturing = sampler.Sampler(Path(work))
            capturing.capture(200, 9 * GIB, "100")
            self.assertEqual(capturing.captures, [])


class SummaryTests(unittest.TestCase):
    def test_summary_reports_each_class_the_top_processes_and_the_selection_at_the_peak(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            write_rows(directory, [
                row("100", 6, 4, 1, 3, 1, 0, 1, 2.0, 3,
                    [[200, "swiftpm-testing-helper", 2 * GIB, 3 * GIB, "2-of-6"], [100, "swift-frontend", GIB, GIB, ""]]),
                row("105", 10, 5, 4, 2, 1, 1, 2, 24.0, 9,
                    [[200, "swiftpm-testing-helper", 8 * GIB, 9 * GIB, ""], [300, "xctest", GIB, GIB, "3-of-6"]]),
                row("110", 8, 3, 4, 5, 1, 0, 1, 6.0, None, None),
            ])
            (directory / sampler.MACHINE).write_text(f"12 {32 * GIB}\n")
            (directory / sampler.MARKS).write_text("101.0,start,2-of-6,150\n102.0,start,3-of-6,160\n"
                                                   "104.0,end,3-of-6,160\n108.0,end,2-of-6,150\n"
                                                   "partial,start,3-of-6,170\n")
            (directory / "footprint-105-200.txt").write_text(FOOTPRINT_TEXT)
            (directory / "footprint-110-300.txt").write_text("footprint: insufficient privileges\n")
            self.enterContext(mock.patch.object(sampler, "FOOTPRINT", str(directory / "absent")))
            lines = sampler.summary(directory)
            facts = json.loads((directory / sampler.SUMMARY).read_text())
        self.assertEqual(lines[0], "Machine: 12 vCPUs, 32.0 GiB.")
        self.assertEqual(lines[3], "| 3 over 10 s | 10.00 | 5.00 | 4.00 | 5.00 | 1.00 | 1.00 | 2 | 10.67 | 24.00 | 24.00 |")
        self.assertIn("Peak used at 00:01:45 UTC, during: 2-of-6.", lines)
        self.assertIn("| `swiftpm-testing-helper` | 200 | 9.00 | 2-of-6 | 00:01:45 |", lines)
        self.assertIn("| `swift-frontend` | 100 | 1.00 | - | 00:01:40 |", lines)
        self.assertIn("| `xctest` | 300 | 1.00 | 3-of-6 | 00:01:45 |", lines)
        self.assertTrue(any("their sum peaked at 9.00 GiB" in line for line in lines))
        self.assertIn(f"`{directory / 'absent'}`: absent, 2 captures in the samples artifact.", lines)
        self.assertIn("- `footprint-105-200.txt`: `swiftpm-testing-helper [200]: 64-bit    Footprint: 9 GB "
                      "(16384 bytes per page)`; `6 GB        0 B          0 B         12    IOAccelerator (graphics)`",
                      lines)
        self.assertIn("- `footprint-110-300.txt`: `footprint: insufficient privileges`", lines)
        self.assertEqual(facts["peaks"]["file_bytes"], {"bytes": 5 * GIB, "time": 110})
        self.assertEqual(facts["peaks"]["footprint_bytes"], {"bytes": 9 * GIB, "time": 105})
        self.assertEqual(facts["selections_at_peak_used"], ["2-of-6"])
        self.assertEqual(facts["scaled_seconds"], {"4": 37.5, "8": 20.0})
        self.assertEqual(facts["busy_vcpus"]["p95"], 24.0)
        self.assertEqual([process["pid"] for process in facts["top_processes"]], [200, 100, 300])

    def test_summary_without_footprints_marks_or_machine_still_reports(self):
        with tempfile.TemporaryDirectory() as work:
            directory = Path(work)
            write_rows(directory, [row("100", 6, 4, 1, 3, 1, 0, 1, 2.0, None, None),
                                   row("105", 7, 4, 2, 3, 1, 0, 1, 1.0, None, None)])
            lines = sampler.summary(directory)
            facts = json.loads((directory / sampler.SUMMARY).read_text())
        self.assertIn("Peak used at 00:01:45 UTC.", lines)
        self.assertFalse(any(line.startswith("| Process") for line in lines))
        self.assertIsNone(facts["peaks"]["footprint_bytes"])
        self.assertNotIn("scaled_seconds", facts)


class LifecycleTests(unittest.TestCase):
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
            github_env = Path(work) / "github-env"
            started = subprocess.run([sys.executable, str(SCRIPT), "start", str(directory), "--interval", "0.05"],
                                     capture_output=True, text=True, timeout=30,
                                     env={**os.environ, "GITHUB_ENV": str(github_env)})
            self.assertEqual(started.returncode, 0, started.stdout + started.stderr)
            # Later steps find the directory for their marks.
            self.assertEqual(github_env.read_text(), f"{sampler.ENVIRONMENT}={directory.resolve()}\n")
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
