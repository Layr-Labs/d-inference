"""Model-free runner guard regressions; execute before actual Swift CPU qualification."""
import importlib.util
import hashlib
import json
import os
from pathlib import Path
import signal
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("calibration_runner", Path(__file__).with_name("run-calibration-tests.py"))
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class LogGuards(unittest.TestCase):
    expected = {"ordinary": 1, "parameterized": 3}
    good = ("✔ Test ordinary() passed after 0.1 seconds.\n"
            "✔ Test parameterized(value:) with 3 test cases passed after 0.2 seconds.\n"
            "✔ Test run with 2 tests passed after 0.3 seconds.\n")

    def test_complete_case_counts(self):
        result = runner.check_test_log(self.good, self.expected)
        self.assertEqual(result["passedInvocations"], 4)
        self.assertEqual(result["skipped"], 0)

    def test_real_parent_swift63_log_and_strict_suite_aggregate(self):
        fixtures = Path(__file__).with_name("Fixtures")
        provenance = json.loads((fixtures / "calibration-swift63-parent.json").read_text())
        with (fixtures / "calibration-swift63-parent.log").open("rb") as handle:
            raw = handle.read(65_537)
        self.assertLessEqual(len(raw), 65_536)
        self.assertEqual(hashlib.sha256(raw).hexdigest(), provenance["logSHA256"])
        text = raw.decode("utf-8")
        expected = provenance["expectedMethods"]
        result = runner.check_test_log(text, expected)
        self.assertEqual(result, {"passedMethods": 18, "passedInvocations": 39, "failed": 0, "skipped": 0})
        aggregate = provenance["aggregate"]
        self.assertIn(aggregate, text)
        # Same real method/case output; reject duplicate aggregate, wrong count,
        # zero suites and missing summary. Both singular/plural formats work.
        plural = text.replace(" in 1 suite ", " in 2 suites ")
        self.assertEqual(runner.check_test_log(plural, expected), result)
        for changed in [text + aggregate + "\n", text.replace("with 18 tests in 1 suite", "with 17 tests in 1 suite"),
                        text.replace(" in 1 suite ", " in 0 suites "), text.replace(aggregate, "")]:
            with self.subTest(aggregate=changed.splitlines()[-1:]), self.assertRaises(ValueError):
                runner.check_test_log(changed, expected)

    def test_zero_incomplete_duplicate_and_partial_case_counts_fail(self):
        for text in ["✔ Test run with 0 tests passed after 0.1 seconds.\n",
                     self.good.replace("✔ Test ordinary() passed after 0.1 seconds.\n", ""),
                     self.good + "✔ Test ordinary() passed after 0.1 seconds.\n",
                     self.good.replace("with 3 test cases", "with 2 test cases")]:
            with self.subTest(text=text), self.assertRaises(ValueError):
                runner.check_test_log(text, self.expected)

    def test_conditional_case_skip_and_failure_never_hide_in_passed_parent(self):
        for line in ["↳ Test case passing 1 argument value → 2 to parameterized(value:) skipped.",
                     "✘ Test ordinary() failed after 0.1 seconds with 1 issue.",
                     "➜ Suite ClusterCalibrationProcessTests skipped: disabled"]:
            with self.subTest(line=line), self.assertRaises(ValueError):
                runner.check_test_log(self.good + line + "\n", self.expected)

    def test_dynamic_or_unknown_test_attribute_fails_closed(self):
        for source in ["@Test(arguments: values) func dynamic() {}", "@Test(.disabled) func disabled() {}"]:
            with self.assertRaises(ValueError):
                runner.expected_cases(source)
        self.assertEqual(runner.expected_cases('@Test func one() {}\n@Test(arguments: [16,17,31]) func more(n: Int) {}'),
                         {"one": 1, "more": 3})


class FixtureOwnership(unittest.TestCase):
    def test_pid_reuse_is_not_signal_authority(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = {"pid": 12345, "uid": os.getuid(), "seconds": 100, "microseconds": 200}
            (root / "12345.json").write_text(json.dumps(original))
            reused = {**original, "microseconds": 201}
            with patch.object(runner, "process_identity", return_value=reused), patch.object(runner.os, "kill") as kill:
                result = runner.cleanup_fixtures(root)
            kill.assert_not_called()
            self.assertTrue(result[0]["originalAbsent"])

    def test_bad_record_does_not_skip_remaining_owned_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "0.json").write_text("invalid JSON")
            identity = {"pid": 12345, "uid": os.getuid(), "seconds": 100, "microseconds": 200}
            (root / "1.json").write_text(json.dumps(identity))
            with patch.object(runner, "process_identity", side_effect=[identity, None, None]), patch.object(runner.os, "kill") as kill:
                result = runner.cleanup_fixtures(root)
            self.assertIn("cleanupError", result[0])
            kill.assert_called_once_with(12345, signal.SIGKILL)
            self.assertTrue(result[1]["originalAbsent"])
            self.assertTrue(result[1]["signalSent"])  # Caller must still fail the gate.


if __name__ == "__main__":
    unittest.main()
