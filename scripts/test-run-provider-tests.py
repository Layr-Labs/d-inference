#!/usr/bin/env python3
"""Exercise the real provider/nested shell routing without invoking Swift or MLX."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
FILTERS = ["defaultApplyProjectsSettings", "stageDelta"]


class ProviderTestRoutingTests(unittest.TestCase):
    def invoke(self, mode="pass"):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for name in ["scripts", "provider-swift", "bin"]:
                (root / name).mkdir()
            for name in ["run-provider-tests.sh", "run-nested-suite.sh"]:
                shutil.copy2(ROOT / "scripts" / name, root / "scripts" / name)
            swift = root / "bin/swift"
            swift.write_text("#!" + sys.executable + "\n" + '''
import json, os, sys
arguments = sys.argv[1:]
name = arguments[arguments.index("--filter") + 1] if "--filter" in arguments else "general"
with open(os.environ["PROVIDER_ROUTE_LOG"], "a") as output:
    output.write(json.dumps({"name": name, "arguments": arguments}) + "\\n")
mode = os.environ["PROVIDER_ROUTE_MODE"]
if mode == "fail:" + name:
    print("Synthetic Swift command failure")
    sys.exit(7 if name == "general" else 9)
if mode == "zero:" + name:
    print("Test run with 0 tests passed after 0.001 seconds.")
elif mode == "skip:" + name:
    print("Test syntheticCase() skipped: missing fixture")
    print("Test run with 1 tests passed after 0.001 seconds.")
else:
    print("Test run with 1 tests passed after 0.001 seconds.")
''')
            swift.chmod(0o755)
            log = root / "calls.jsonl"
            environment = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                               PROVIDER_ROUTE_LOG=str(log), PROVIDER_ROUTE_MODE=mode)
            process = subprocess.run(["bash", str(root / "scripts/run-provider-tests.sh")],
                                     cwd=root / "provider-swift", env=environment,
                                     capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([call["name"] for call in calls], ["general", *FILTERS])
            return process, calls

    def test_general_suite_is_serial_and_each_excluded_case_runs_separately(self):
        process, calls = self.invoke()
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)
        self.assertEqual(calls[0]["arguments"],
                         ["test", "--skip-build", "--no-parallel", "--skip", "|".join(FILTERS)])
        for call, name in zip(calls[1:], FILTERS):
            self.assertEqual(call["arguments"], ["test", "--skip-build", "--filter", name])

    def test_general_failure_does_not_silence_isolated_gates_or_turn_green(self):
        process, _ = self.invoke("fail:general")
        self.assertEqual(process.returncode, 7)

    def test_each_isolated_failure_survives_later_success(self):
        for name in FILTERS:
            with self.subTest(name=name):
                process, _ = self.invoke("fail:" + name)
                self.assertEqual(process.returncode, 9)

    def test_zero_count_isolated_gate_cannot_pass(self):
        for name in FILTERS:
            with self.subTest(name=name):
                process, _ = self.invoke("zero:" + name)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("executed ZERO tests", process.stdout)

    def test_skipped_isolated_gate_cannot_pass(self):
        for name in FILTERS:
            with self.subTest(name=name):
                process, _ = self.invoke("skip:" + name)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("skipped one or more tests", process.stdout)


if __name__ == "__main__":
    unittest.main()
