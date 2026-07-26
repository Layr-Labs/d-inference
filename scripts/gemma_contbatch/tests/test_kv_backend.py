"""The KV-backend posture the wrapper is required to hold.

Three things are under test, in the order they matter:

1. a comparison across differing backends is REFUSED (the delta would be a
   backend change wearing a performance change's clothes);
2. the run's resolved backend reaches the report at all;
3. the argv actually carries `--kv-backend` and `--batch-sizes`, on a curve
   that reaches B=8.

The full benchmark needs release weights and a Metal GPU, so `main()` is
driven here against synthetic payloads with the subprocess boundary stubbed.
"""

from __future__ import annotations

import argparse
import contextlib
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from .. import runner
from ..backend import resolve_kv_backend, validate_kv_backend_pin
from ..config import DEFAULT_BATCH_SIZES, DEFAULT_KV_BACKEND, parse_args
from ..report import markdown_report
from . import fixtures


PREFILL_LENGTHS = [128, 512]
BATCH_SIZES = [1, 2, 4, 8]
ITERATIONS = 2
DECODE_TOKENS = 64


def make_args(**overrides) -> argparse.Namespace:
    values = {
        "model": fixtures.MODEL_ID,
        "iterations": ITERATIONS,
        "prefill_lengths": list(PREFILL_LENGTHS),
        "batch_sizes": list(BATCH_SIZES),
        "kv_backend": "paged",
        "decode_prompt_tokens": 64,
        "decode_tokens": DECODE_TOKENS,
        "arrival_prompt_tokens": 512,
        "arrival_decode_tokens": 64,
        "label": "",
        "output_dir": "tmp/benchmarks",
        "baseline": None,
        "skip_build": True,
        "skip_metallib": True,
    }
    values.update(overrides)
    return argparse.Namespace(**values)


def make_sweep(**overrides) -> dict:
    return fixtures.sweep_payload(
        prefill_lengths=PREFILL_LENGTHS,
        batch_sizes=BATCH_SIZES,
        iterations=ITERATIONS,
        decode_tokens=DECODE_TOKENS,
        **overrides,
    )


class SweepArgvTests(unittest.TestCase):
    def test_forwards_backend_and_batch_sizes(self):
        argv = runner.sweep_argv(["darkbloom", "benchmark", "--model", "m"], make_args())
        self.assertEqual(
            argv,
            [
                "darkbloom",
                "benchmark",
                "--model",
                "m",
                "--sweep",
                "--prefill-lengths",
                "128,128,512,512",
                "--kv-backend",
                "paged",
                "--batch-sizes",
                "1,2,4,8",
                "--decode-tokens",
                "64",
                "--decode-prompt-tokens",
                "64",
                "--decode-iterations",
                "2",
            ],
        )

    def test_no_max_batch_ladder_remains(self):
        # The ladder is what capped the canonical run at B=4. If it comes
        # back, the curve stops below the ~B=5 crossover again.
        argv = runner.sweep_argv(["darkbloom"], make_args())
        self.assertNotIn("--max-batch", argv)


class DefaultPostureTests(unittest.TestCase):
    def test_defaults_are_paged_and_reach_eight(self):
        with mock.patch.object(sys, "argv", ["benchmark-gemma-contbatch.py"]):
            args = parse_args()
        self.assertEqual(args.kv_backend, "paged")
        self.assertEqual(args.kv_backend, DEFAULT_KV_BACKEND)
        self.assertEqual(args.batch_sizes, list(DEFAULT_BATCH_SIZES))
        # The claim this release makes (1.17x aggregate) lives at B=8; a curve
        # that stops earlier cannot observe it.
        self.assertEqual(max(args.batch_sizes), 8)

    def test_auto_is_still_reachable_for_a_deliberate_run(self):
        with mock.patch.object(
            sys, "argv", ["x", "--kv-backend", "auto", "--batch-sizes", "1,8"]
        ):
            args = parse_args()
        self.assertEqual(args.kv_backend, "auto")
        self.assertEqual(args.batch_sizes, [1, 8])


class ResolveKVBackendTests(unittest.TestCase):
    def test_records_selection_and_resolution_separately(self):
        block = resolve_kv_backend(make_args(), make_sweep())
        self.assertEqual(block["selection"], "paged")
        self.assertEqual(block["resolved"], ["paged"])
        self.assertEqual(block["byBatchSize"], {"1": "paged", "2": "paged", "4": "paged", "8": "paged"})
        self.assertEqual(block["postureViolations"], [])

    def test_degraded_cell_is_a_violation_not_a_green_run(self):
        # The defect this ticket exists for: `auto` holding paged at B=1 and
        # degrading at B=8 while every other check stays green.
        sweep = make_sweep(
            selection="auto",
            resolved_by_batch={
                1: "paged",
                2: "paged",
                4: "paged",
                8: "contiguous (fallback: pool capacity)",
            },
        )
        block = resolve_kv_backend(make_args(kv_backend="auto"), sweep)
        self.assertEqual(block["resolved"], ["contiguous", "paged"])
        self.assertEqual(block["byBatchSize"]["8"], "contiguous")
        self.assertEqual(len(block["postureViolations"]), 1)
        self.assertIn("mixed KV backend population", block["postureViolations"][0])
        self.assertIn("B=8: contiguous", block["postureViolations"][0])

    def test_explicit_paged_resolving_contiguous_is_a_violation(self):
        sweep = make_sweep(selection="paged", resolved="contiguous")
        block = resolve_kv_backend(make_args(), sweep)
        self.assertEqual(
            block["postureViolations"], ["--kv-backend paged resolved contiguous"]
        )

    def test_report_without_the_block_is_refused(self):
        sweep = make_sweep()
        del sweep["kvBackend"]
        with self.assertRaisesRegex(RuntimeError, "predates schema 3"):
            resolve_kv_backend(make_args(), sweep)

    def test_cell_without_a_resolved_backend_is_refused(self):
        sweep = make_sweep()
        sweep["decode"][2]["resolvedKVBackend"] = None
        with self.assertRaisesRegex(RuntimeError, "without recording a backend"):
            resolve_kv_backend(make_args(), sweep)

    def test_selection_drift_between_wrapper_and_binary_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "but this wrapper requested"):
            resolve_kv_backend(make_args(kv_backend="contiguous"), make_sweep())

    def test_unknown_kind_is_refused_rather_than_compared(self):
        sweep = make_sweep(resolved_by_batch={1: "quantized-pages"})
        with self.assertRaisesRegex(RuntimeError, "unrecognised KV backend kind"):
            resolve_kv_backend(make_args(), sweep)


class BackendPinTests(unittest.TestCase):
    def setUp(self):
        self.current = resolve_kv_backend(make_args(), make_sweep())

    def test_matching_backend_compares(self):
        baseline = {"kvBackend": dict(self.current)}
        validate_kv_backend_pin(baseline, self.current)

    def test_contiguous_baseline_refuses_a_paged_run(self):
        baseline = {
            "kvBackend": {
                "selection": "contiguous",
                "resolved": ["contiguous"],
                "byBatchSize": dict.fromkeys(["1", "2", "4", "8"], "contiguous"),
            }
        }
        with self.assertRaises(RuntimeError) as caught:
            validate_kv_backend_pin(baseline, self.current)
        message = str(caught.exception)
        self.assertIn("compare across backend populations", message)
        self.assertIn("selection='paged' (baseline 'contiguous')", message)
        self.assertIn("resolved=['paged'] (baseline ['contiguous'])", message)

    def test_baseline_predating_the_record_refuses(self):
        with self.assertRaisesRegex(RuntimeError, "does not record a resolved KV backend"):
            validate_kv_backend_pin({"summary": {}}, self.current)

    def test_per_cell_disagreement_refuses_even_when_the_set_matches(self):
        # Both runs saw {paged, contiguous}, but on different batch sizes, so
        # every per-batch delta in the report is cross-population.
        mixed = resolve_kv_backend(
            make_args(kv_backend="auto"),
            make_sweep(selection="auto", resolved_by_batch={8: "contiguous"}),
        )
        baseline = {
            "kvBackend": {
                "selection": "auto",
                "resolved": ["contiguous", "paged"],
                "byBatchSize": {
                    "1": "contiguous",
                    "2": "paged",
                    "4": "paged",
                    "8": "paged",
                },
            }
        }
        with self.assertRaises(RuntimeError) as caught:
            validate_kv_backend_pin(baseline, mixed)
        message = str(caught.exception)
        self.assertIn("B=1: 'paged' (baseline 'contiguous')", message)
        self.assertIn("B=8: 'contiguous' (baseline 'paged')", message)


class DryRunTests(unittest.TestCase):
    """`main()` end to end with the subprocess boundary replaced."""

    def run_main(self, args: argparse.Namespace, sweep: dict, output_dir: Path) -> int:
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
        self.commands: list[list[str]] = []

        def fake_run_json(command, cwd):
            self.commands.append(command)
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
            # `main` prints the whole markdown report; the suite asserts on
            # the artifact instead of the console.
            with contextlib.redirect_stdout(io.StringIO()):
                return runner.main()

    def latest_report(self, output_dir: Path) -> dict:
        return json.loads(
            (output_dir / "gemma-contbatch-latest.json").read_text(encoding="utf-8")
        )

    def test_clean_paged_run_records_the_backend_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            status = self.run_main(make_args(), make_sweep(), output_dir)
            self.assertEqual(status, 0)
            report = self.latest_report(output_dir)

        self.assertEqual(report["kvBackend"]["selection"], "paged")
        self.assertEqual(report["kvBackend"]["resolved"], ["paged"])
        self.assertEqual(report["configuration"]["batchSizes"], BATCH_SIZES)
        self.assertNotIn("maxBatch", report["configuration"])
        # The forwarded flags, as actually handed to the binary.
        sweep_command = next(item for item in self.commands if "--sweep" in item)
        self.assertIn("--kv-backend", sweep_command)
        self.assertEqual(
            sweep_command[sweep_command.index("--batch-sizes") + 1], "1,2,4,8"
        )
        markdown = markdown_report(report)
        self.assertIn("## KV Backend", markdown)
        self.assertIn("- KV backend posture: PASS", markdown)

    def test_degraded_run_writes_the_report_and_exits_non_zero(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            status = self.run_main(
                make_args(kv_backend="auto"),
                make_sweep(selection="auto", resolved_by_batch={8: "contiguous"}),
                output_dir,
            )
            report = self.latest_report(output_dir)
            markdown = (output_dir / "gemma-contbatch-latest.md").read_text(
                encoding="utf-8"
            )

        # The artifact is what an operator needs precisely when the posture
        # broke, so it is written before the process fails.
        self.assertEqual(status, 1)
        self.assertEqual(report["kvBackend"]["resolved"], ["contiguous", "paged"])
        self.assertIn("- KV backend posture: FAIL", markdown)

    def test_comparison_against_a_contiguous_baseline_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.run_main(make_args(), make_sweep(), output_dir)
            paged_report = output_dir / "gemma-contbatch-latest.json"
            baseline = json.loads(paged_report.read_text(encoding="utf-8"))
            baseline["kvBackend"] = {
                "selection": "contiguous",
                "resolved": ["contiguous"],
                "resolvedDescriptors": ["contiguous"],
                "byBatchSize": dict.fromkeys(["1", "2", "4", "8"], "contiguous"),
                "postureViolations": [],
            }
            baseline_path = output_dir / "baseline.json"
            baseline_path.write_text(json.dumps(baseline), encoding="utf-8")

            with self.assertRaises(RuntimeError) as caught:
                self.run_main(
                    make_args(baseline=str(baseline_path)),
                    make_sweep(),
                    output_dir,
                )
        self.assertIn("compare across backend populations", str(caught.exception))

    def test_comparison_against_a_matching_paged_baseline_proceeds(self):
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            self.run_main(make_args(), make_sweep(), output_dir)
            baseline_path = output_dir / "baseline.json"
            baseline_path.write_text(
                (output_dir / "gemma-contbatch-latest.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            status = self.run_main(
                make_args(baseline=str(baseline_path)), make_sweep(), output_dir
            )
            report = self.latest_report(output_dir)

        self.assertEqual(status, 0)
        self.assertIn("comparison", report)
        self.assertEqual(
            [item["batchSize"] for item in report["comparison"]["decode"]], BATCH_SIZES
        )


if __name__ == "__main__":
    unittest.main()
