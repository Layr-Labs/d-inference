#!/usr/bin/env python3
"""The concurrent check runner, with real bash and Python child processes."""

import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/run-concurrent-checks.py"


class ConcurrentChecksTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="run-concurrent-checks-test-")
        self.addCleanup(temporary.cleanup)
        self.shared = Path(temporary.name)
        self.scripts = 0

    def python(self, source):
        """A command line (one line, as the runner reads) that runs `source` in a fresh Python."""
        self.scripts += 1
        script = self.shared / f"script-{self.scripts}.py"
        script.write_text(textwrap.dedent(source).strip() + "\n")
        return f"{shlex.quote(sys.executable)} {shlex.quote(str(script))}"

    def run_checks(self, *commands, jobs=None, timeout=60):
        arguments = [sys.executable, str(SCRIPT)] + ([f"--jobs={jobs}"] if jobs else [])
        return subprocess.run(arguments, input="\n".join(commands) + "\n", capture_output=True, text=True,
                              timeout=timeout, env={**os.environ, "SHARED": str(self.shared)})

    def barrier(self, group, name, parties, seconds=10):
        """A command that passes only if `parties` commands of `group` run at the same time."""
        return self.python(f"""
            import os, pathlib, time
            here = pathlib.Path(os.environ["SHARED"]) / "barrier-{group}"
            here.mkdir(exist_ok=True)
            (here / "{name}").touch()
            deadline = time.monotonic() + {seconds}
            while len(list(here.iterdir())) < {parties}:
                if time.monotonic() > deadline:
                    raise SystemExit("{name}: the other commands never ran beside this one")
                time.sleep(0.02)
            print("{name}: all {parties} ran at once")
            """)

    def test_commands_run_at_the_same_time(self):
        result = self.run_checks(*(self.barrier("together", f"c{index}", 3) for index in range(3)), jobs=3)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for index in range(3):
            self.assertIn(f"c{index}: all 3 ran at once", result.stdout)
        self.assertIn("3 commands in", result.stdout)
        self.assertIn("3 passed, 0 failed", result.stdout)

    def test_jobs_bounds_how_many_run_at_once(self):
        record = self.python("""
            import os, pathlib, time
            running = pathlib.Path(os.environ["SHARED"]) / "running"
            running.mkdir(exist_ok=True)
            mine = running / str(os.getpid())
            mine.touch()
            with open(pathlib.Path(os.environ["SHARED"]) / "seen", "a") as seen:
                seen.write(f"{len(list(running.iterdir()))}\\n")
            time.sleep(0.3)
            mine.unlink()
            """)
        result = self.run_checks(*[record] * 6, jobs=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        seen = [int(line) for line in (self.shared / "seen").read_text().split()]
        self.assertEqual(len(seen), 6)
        self.assertLessEqual(max(seen), 2)
        # One at a time, the first of two commands that must meet waits alone and fails.
        alone = self.run_checks(self.barrier("alone", "a", 2, seconds=2), self.barrier("alone", "b", 2), jobs=1)
        self.assertEqual(alone.returncode, 1)
        self.assertIn("a: the other commands never ran beside this one", alone.stdout)

    def test_each_output_is_whole_and_in_the_listed_order(self):
        slow = self.python("""
            import time
            for line in range(3):
                print(f"slow {line}", flush=True)
                time.sleep(0.2)
            """)
        fast = self.python('print("fast 0"); print("fast 1")')
        result = self.run_checks(slow, fast, jobs=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        lines = [line for line in result.stdout.splitlines() if re.match(r"(slow|fast) \d$", line)]
        self.assertEqual(lines, ["slow 0", "slow 1", "slow 2", "fast 0", "fast 1"])
        blocks = re.findall(r"(?m)^==> \[(\d)/2\] .*$\n((?:.*\n)*?)^<== \[\1/2\] .*: passed in \d+\.\d s$", result.stdout)
        self.assertEqual([number for number, _ in blocks], ["1", "2"])
        self.assertEqual(blocks[0][1], "slow 0\nslow 1\nslow 2\n")
        self.assertEqual(blocks[1][1], "fast 0\nfast 1\n")

    def test_any_failure_fails_the_run_after_every_command_ran_once(self):
        count = self.python("""
            import os, pathlib
            with open(pathlib.Path(os.environ["SHARED"]) / "runs", "a") as runs:
                runs.write("ran\\n")
            """)
        result = self.run_checks(count, "echo broken >&2; exit 3", count, "exit 0", jobs=4)
        self.assertEqual(result.returncode, 1)
        # No retry: the failing command ran once, and every other command ran.
        self.assertEqual((self.shared / "runs").read_text(), "ran\nran\n")
        self.assertIn("broken\n<== [2/4] echo broken >&2; exit 3: FAILED (exit 3) in", result.stdout)
        self.assertIn("4 commands in", result.stdout)
        self.assertIn("3 passed, 1 failed", result.stdout)
        self.assertIn("::error title=Check failed::echo broken >&2; exit 3 exited 3 after", result.stdout)
        missing = self.run_checks("./does-not-exist.sh")
        self.assertEqual(missing.returncode, 1)
        self.assertRegex(missing.stdout, r"No such file or directory\n<== \[1/1\] \./does-not-exist\.sh: FAILED \(exit \d+\)")

    def test_a_command_ended_by_a_signal_fails(self):
        result = self.run_checks("kill -KILL $$", "echo after")
        self.assertEqual(result.returncode, 1)
        self.assertIn("<== [1/2] kill -KILL $$: FAILED (exit -9) in", result.stdout)
        self.assertIn("1 passed, 1 failed", result.stdout)

    def test_a_failing_pipeline_fails_its_command(self):
        result = self.run_checks("false | cat")
        self.assertEqual(result.returncode, 1)
        self.assertIn("FAILED (exit 1)", result.stdout)

    def test_each_command_has_a_private_temporary_directory_and_the_callers_environment(self):
        show = self.python("""
            import os, tempfile
            print("tmp", os.environ["TMPDIR"], os.path.isdir(os.environ["TMPDIR"]))
            print("tempfile", tempfile.gettempdir())
            print("shared", os.environ["SHARED"])
            """)
        result = self.run_checks(show, show, jobs=2)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        directories = re.findall(r"(?m)^tmp (\S+) True$", result.stdout)
        self.assertEqual(len(directories), 2)
        self.assertNotEqual(directories[0], directories[1])
        self.assertEqual(re.findall(r"(?m)^tempfile (\S+)$", result.stdout), directories)
        self.assertEqual(re.findall(r"(?m)^shared (\S+)$", result.stdout), [str(self.shared)] * 2)
        # The shell expands the caller's variables, as in a workflow step.
        expanded = self.run_checks('test "$SHARED" = ' + shlex.quote(str(self.shared)))
        self.assertEqual(expanded.returncode, 0, expanded.stdout)

    def test_commands_read_no_input(self):
        result = self.run_checks(self.python("import sys; print(repr(sys.stdin.read()))"), timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("''\n", result.stdout)

    def test_comments_and_blank_lines_are_skipped_and_an_empty_list_fails(self):
        result = self.run_checks("# a comment", "", "  echo one  ", "   # indented comment")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("==> [1/1] echo one\none\n", result.stdout)
        empty = self.run_checks("# only a comment", "")
        self.assertEqual(empty.returncode, 2)
        self.assertIn("::error title=Checks::No command to run", empty.stdout)

    def test_reads_the_commands_from_a_file(self):
        listing = self.shared / "commands"
        listing.write_text("echo from-file\n")
        result = subprocess.run([sys.executable, str(SCRIPT), str(listing)], capture_output=True, text=True,
                                timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("from-file\n", result.stdout)
        refused = subprocess.run([sys.executable, str(SCRIPT), "--jobs=0", str(listing)], capture_output=True,
                                 text=True, timeout=30)
        self.assertEqual(refused.returncode, 2)


if __name__ == "__main__":
    unittest.main()
