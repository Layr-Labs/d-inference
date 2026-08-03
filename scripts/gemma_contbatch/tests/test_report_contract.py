"""The wrapper's two report-contract obligations.

1. A benchmark that FAILED still hands back what it reported. An explicit
   `--kv-backend` sweep that cannot build a requested cell prints its
   structured report and then exits non-zero on purpose: the report names the
   cells that went unmeasured and why. Deciding to abort on the status before
   parsing stdout threw exactly that away.
2. A baseline written against a different wrapper schema is REFUSED. Schema 3
   dropped `configuration.maxBatch` for `configuration.batchSizes` and added
   the top-level `kvBackend` block, so a schema-2 baseline makes every pin
   read a renamed field as "not recorded" and the comparison silently comes
   out as a same-shape delta between two different experiments.
"""

from __future__ import annotations

import contextlib
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .. import runner
from ..baseline import validate_schema_version_pin
from ..process import BenchmarkCommandFailure, run_json
from ..config import SCHEMA_VERSION
from . import fixtures
from .test_kv_backend import make_args, make_sweep


def python_command(script: str) -> list[str]:
    return [sys.executable, "-c", script]


class RunJSONFailureTests(unittest.TestCase):
    """Against a real subprocess -- the status/stdout interleaving is the bug."""

    def test_non_zero_exit_still_yields_the_parsed_report(self):
        script = (
            "import sys;"
            "print('{\"decodeCoverage\": {\"unmeasured\": [{\"batchSize\": 8}]}}');"
            "sys.exit(3)"
        )
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(BenchmarkCommandFailure) as caught:
                run_json(python_command(script), Path.cwd())
        failure = caught.exception
        # The status is still the child's -- only the discard was wrong.
        self.assertEqual(failure.returncode, 3)
        self.assertEqual(
            failure.report["decodeCoverage"]["unmeasured"], [{"batchSize": 8}]
        )

    def test_non_zero_exit_without_a_report_is_still_refused(self):
        script = "import sys; sys.exit(2)"
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(BenchmarkCommandFailure) as caught:
                run_json(python_command(script), Path.cwd())
        self.assertEqual(caught.exception.returncode, 2)
        self.assertIsNone(caught.exception.report)
        self.assertIn("no structured report", str(caught.exception))

    def test_zero_exit_with_broken_json_is_not_a_command_failure(self):
        script = "print('not json')"
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "invalid JSON"):
                run_json(python_command(script), Path.cwd())


class FailedSweepArtifactTests(unittest.TestCase):
    """`main()` keeps the report a refused sweep printed, and its status."""

    def run_main(self, args, output_dir: Path, failure: BenchmarkCommandFailure) -> int:
        args.output_dir = str(output_dir)

        def fake_run_json(command, cwd):
            if "--sweep" in command:
                raise failure
            raise AssertionError(f"unexpected invocation after failure: {command}")

        with (
            mock.patch.object(runner, "parse_args", return_value=args),
            mock.patch.object(runner, "run_json", fake_run_json),
            mock.patch.object(runner, "capture", lambda command, cwd: "deadbeef"),
            mock.patch.object(runner, "capture_optional", lambda command, cwd: "nominal"),
            mock.patch.object(runner, "sha256", lambda path: "0" * 64),
            mock.patch.object(runner, "source_fingerprint", lambda path: ([], "f" * 64)),
            mock.patch.object(runner.Path, "is_file", lambda self: True),
        ):
            with contextlib.redirect_stdout(io.StringIO()):
                with contextlib.redirect_stderr(io.StringIO()):
                    return runner.main()

    def test_refused_sweep_writes_its_report_and_propagates_the_status(self):
        printed = make_sweep(
            unmeasured=[{"batchSize": 8, "reason": "paged pool too small"}]
        )
        failure = BenchmarkCommandFailure(["darkbloom", "benchmark"], 1, printed)
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            status = self.run_main(make_args(), output_dir, failure)
            artifact = json.loads(
                (output_dir / "gemma-contbatch-failed.json").read_text(encoding="utf-8")
            )

        self.assertEqual(status, 1)
        self.assertEqual(artifact["exitStatus"], 1)
        self.assertEqual(artifact["report"], printed)

    def test_failure_without_a_report_writes_nothing_but_still_fails(self):
        failure = BenchmarkCommandFailure(["darkbloom", "benchmark"], 4, None)
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            status = self.run_main(make_args(), output_dir, failure)
            self.assertFalse((output_dir / "gemma-contbatch-failed.json").exists())
        self.assertEqual(status, 4)


class SchemaVersionPinTests(unittest.TestCase):
    def test_current_version_passes(self):
        validate_schema_version_pin({"schemaVersion": SCHEMA_VERSION})

    def test_schema_two_baseline_is_refused(self):
        with self.assertRaises(RuntimeError) as caught:
            validate_schema_version_pin({"schemaVersion": 2})
        message = str(caught.exception)
        self.assertIn("baseline schemaVersion is 2", message)
        self.assertIn(f"this runner writes {SCHEMA_VERSION}", message)

    def test_baseline_without_a_version_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "baseline schemaVersion is None"):
            validate_schema_version_pin({})


class SchemaVersionThroughMainTests(unittest.TestCase):
    """The end the reviewer cares about: an old baseline cannot mis-compare."""

    def run_main(self, args, sweep, output_dir: Path) -> int:
        args.output_dir = str(output_dir)
        payloads = {
            "--sweep": sweep,
            "--scheduler-prefill": fixtures.scheduler_payload(
                prefill_lengths=args.prefill_lengths, iterations=args.iterations
            ),
            "--arrival-invariance": fixtures.arrival_payload(
                iterations=args.iterations,
                prompt_tokens=args.arrival_prompt_tokens,
                decode_tokens=args.arrival_decode_tokens,
            ),
        }

        def fake_run_json(command, cwd):
            for flag, payload in payloads.items():
                if flag in command:
                    return payload
            raise AssertionError(f"unexpected benchmark invocation: {command}")

        with (
            mock.patch.object(runner, "parse_args", return_value=args),
            mock.patch.object(runner, "run_json", fake_run_json),
            mock.patch.object(runner, "capture", lambda command, cwd: "deadbeef"),
            mock.patch.object(runner, "capture_optional", lambda command, cwd: "nominal"),
            mock.patch.object(runner, "sha256", lambda path: "0" * 64),
            mock.patch.object(runner, "source_fingerprint", lambda path: ([], "f" * 64)),
            mock.patch.object(runner.Path, "is_file", lambda self: True),
            mock.patch.object(runner, "performance_environment", lambda env: {}),
        ):
            with contextlib.redirect_stdout(io.StringIO()):
                return runner.main()

    def test_report_advertises_the_current_schema(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.run_main(make_args(), make_sweep(), output_dir)
            report = json.loads(
                (output_dir / "gemma-contbatch-latest.json").read_text(encoding="utf-8")
            )
        self.assertEqual(report["schemaVersion"], SCHEMA_VERSION)
        self.assertNotIn("maxBatch", report["configuration"])
        self.assertIn("kvBackend", report)

    def test_schema_two_baseline_is_refused_rather_than_compared(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.run_main(make_args(), make_sweep(), output_dir)
            baseline = json.loads(
                (output_dir / "gemma-contbatch-latest.json").read_text(encoding="utf-8")
            )
            # A pre-#590 report: schema 2, a maxBatch ceiling instead of the
            # enumerated ladder, and no backend recorded anywhere.
            baseline["schemaVersion"] = 2
            baseline["configuration"]["maxBatch"] = max(
                baseline["configuration"].pop("batchSizes")
            )
            baseline.pop("kvBackend")
            baseline_path = output_dir / "baseline.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")

            with self.assertRaises(RuntimeError) as caught:
                self.run_main(
                    make_args(baseline=str(baseline_path)), make_sweep(), output_dir
                )
            report = json.loads(
                (output_dir / "gemma-contbatch-latest.json").read_text(encoding="utf-8")
            )

        self.assertIn("baseline schemaVersion is 2", str(caught.exception))
        # Refused before any delta was computed.
        self.assertNotIn("comparison", report)


if __name__ == "__main__":
    unittest.main()
