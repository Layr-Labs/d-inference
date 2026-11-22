#!/usr/bin/env python3
"""ci-background-step.py: a background command's status reaches a later step, and only success passes.

Run: python3 scripts/test-ci-background-step.py
"""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import tempfile
import time
import unittest


SPEC = importlib.util.spec_from_file_location("ci_background_step", Path(__file__).resolve().parent / "ci-background-step.py")
background = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(background)


class BackgroundStep(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.directory = self.work / "job"

    def run_main(self, *argv):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            code = background.main(list(argv))
        return code, output.getvalue()

    def test_a_succeeding_command_passes_and_its_output_is_printed(self):
        code, _ = self.run_main("start", str(self.directory), "sh", "-c", "sleep 0.5; echo built; pwd")
        self.assertEqual(code, 0)
        # The start step returns while the command still runs.
        self.assertFalse((self.directory / "status").exists())
        code, output = self.run_main("wait", str(self.directory))
        self.assertEqual(code, 0)
        self.assertIn("ended with status 0", output)
        self.assertIn("built\n", output)
        self.assertIn(str(Path.cwd().resolve()) + "\n", output)

    def test_a_failing_command_fails_the_wait(self):
        self.run_main("start", str(self.directory), "sh", "-c", "echo broken >&2; exit 3")
        code, output = self.run_main("wait", str(self.directory))
        self.assertEqual(code, 1)
        self.assertIn("broken", output)
        self.assertIn("::error title=Background command::The background command failed with status 3", output)

    def test_a_command_that_cannot_start_fails_the_wait(self):
        self.run_main("start", str(self.directory), str(self.work / "missing-command"))
        code, output = self.run_main("wait", str(self.directory))
        self.assertEqual(code, 1)
        self.assertIn("failed with status 127", output)

    def test_the_command_runs_in_its_own_session(self):
        with contextlib.redirect_stdout(io.StringIO()):
            process = background.start(self.directory, ["sleep", "1"])
        self.assertEqual(os.getsid(process.pid), process.pid)
        process.wait()

    def test_the_wait_ends_with_an_error_at_its_limit_and_prints_the_output_so_far(self):
        self.directory.mkdir()
        (self.directory / "output.log").write_text("compiling kernels\n[ 42%] Building")
        now = [0.0]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(TimeoutError, "had not ended after 30 s"):
            background.wait(self.directory, limit=30, poll=10, clock=lambda: now[0],
                            sleep=lambda seconds: now.__setitem__(0, now[0] + seconds))
        self.assertEqual(now[0], 30)
        self.assertIn("compiling kernels\n[ 42%] Building\n::endgroup::\n", output.getvalue())

    def test_start_refuses_a_used_directory(self):
        self.directory.mkdir()
        with self.assertRaises(FileExistsError):
            background.start(self.directory, ["true"])


if __name__ == "__main__":
    unittest.main()
