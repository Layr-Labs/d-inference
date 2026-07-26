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


def make_scheduler(**overrides) -> dict:
    return fixtures.scheduler_payload(
        prefill_lengths=PREFILL_LENGTHS, iterations=ITERATIONS, **overrides
    )


def make_arrival(**overrides) -> dict:
    return fixtures.arrival_payload(
        iterations=ITERATIONS, prompt_tokens=512, decode_tokens=64, **overrides
    )


def resolve(
    args: argparse.Namespace | None = None,
    sweep: dict | None = None,
    scheduler: dict | None = None,
    arrival: dict | None = None,
) -> dict:
    """`resolve_kv_backend` over all three phases of a run.

    Unless a test hands in its own payload, the two non-sweep phases agree
    with the sweep's first decode cell: the wrapper now forwards one
    selection to all three commands, so agreement is the ordinary case and a
    test that wants a mixed-arm run says so explicitly.
    """
    args = make_args() if args is None else args
    sweep = make_sweep() if sweep is None else sweep
    # `.get` chains: tests that strip the sweep's block to prove it is
    # required must still reach `resolve_kv_backend` to be refused there.
    selection = sweep.get("kvBackend", {}).get("selection", "paged")
    resolved = sweep["decode"][0].get("resolvedKVBackend") or "paged"
    return resolve_kv_backend(
        args,
        sweep,
        make_scheduler(selection=selection, resolved=resolved)
        if scheduler is None
        else scheduler,
        make_arrival(selection=selection, resolved=resolved)
        if arrival is None
        else arrival,
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


class PhaseArgvTests(unittest.TestCase):
    """Every engine-constructing command carries the selection, not just the
    sweep. Without this the two phases below took `--kv-backend`'s default of
    `auto` and resolved whatever it happened to land on, so a run reporting
    one backend could have measured the other for two of its three phases."""

    def test_scheduler_prefill_carries_the_selection(self):
        argv = runner.scheduler_argv(
            ["darkbloom", "benchmark", "--model", "m"], make_args()
        )
        self.assertEqual(
            argv,
            [
                "darkbloom",
                "benchmark",
                "--model",
                "m",
                "--scheduler-prefill",
                "--prefill-lengths",
                "128,512",
                "--kv-backend",
                "paged",
                "--prefill-iterations",
                "2",
            ],
        )

    def test_arrival_invariance_carries_the_selection(self):
        argv = runner.arrival_argv(
            ["darkbloom", "benchmark", "--model", "m"], make_args()
        )
        self.assertEqual(
            argv,
            [
                "darkbloom",
                "benchmark",
                "--model",
                "m",
                "--arrival-invariance",
                "--kv-backend",
                "paged",
                "--arrival-prompt-tokens",
                "512",
                "--arrival-decode-tokens",
                "64",
                "--arrival-iterations",
                "2",
            ],
        )

    def test_a_deliberate_auto_run_forwards_auto_everywhere(self):
        args = make_args(kv_backend="auto")
        for argv in (
            runner.sweep_argv(["darkbloom"], args),
            runner.scheduler_argv(["darkbloom"], args),
            runner.arrival_argv(["darkbloom"], args),
        ):
            self.assertEqual(argv[argv.index("--kv-backend") + 1], "auto")


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
        block = resolve()
        self.assertEqual(block["selection"], "paged")
        self.assertEqual(block["resolved"], ["paged"])
        self.assertEqual(block["byBatchSize"], {"1": "paged", "2": "paged", "4": "paged", "8": "paged"})
        self.assertEqual(
            block["byPhase"],
            {
                "throughputSweep": "paged",
                "schedulerPrefill": "paged",
                "arrivalInvariance": "paged",
            },
        )
        self.assertEqual(block["postureViolations"], [])

    def test_degraded_cell_is_a_violation_not_a_green_run(self):
        # `auto` holding paged at B=1 and degrading at B=8 while every other
        # check stays green.
        sweep = make_sweep(
            selection="auto",
            resolved_by_batch={
                1: "paged",
                2: "paged",
                4: "paged",
                8: "contiguous (fallback: pool capacity)",
            },
        )
        block = resolve(make_args(kv_backend="auto"), sweep)
        self.assertEqual(block["resolved"], ["contiguous", "paged"])
        self.assertEqual(block["byBatchSize"]["8"], "contiguous")
        decode_violation = next(
            item for item in block["postureViolations"] if "decode curve" in item
        )
        self.assertIn("mixed KV backend population", decode_violation)
        self.assertIn("B=8: contiguous", decode_violation)

    def test_a_phase_on_the_other_backend_is_a_violation(self):
        # The defect this ticket exists for: the sweep names one backend and
        # the two phases beside it, unpinned, measured whatever their own
        # engine resolved -- a degrade to contiguous being the likely way
        # they diverge. A report that averaged the three would attribute
        # contiguous behaviour to a paged run.
        block = resolve(
            scheduler=make_scheduler(selection="paged", resolved="contiguous")
        )
        self.assertEqual(block["resolved"], ["contiguous", "paged"])
        self.assertEqual(block["byPhase"]["schedulerPrefill"], "contiguous")
        self.assertEqual(block["byPhase"]["throughputSweep"], "paged")
        mixed = next(
            item for item in block["postureViolations"] if "across phases" in item
        )
        self.assertIn("schedulerPrefill: contiguous", mixed)
        self.assertIn("arrivalInvariance: paged", mixed)
        # And the explicit selection was not honoured end to end.
        self.assertIn(
            "--kv-backend paged resolved contiguous", block["postureViolations"]
        )

    def test_phase_degrade_reason_reaches_the_report(self):
        # A phase that degraded is the only place its reason is recorded; the
        # sweep block cannot speak for an engine it did not build.
        block = resolve(
            arrival=make_arrival(
                selection="paged",
                resolved="contiguous (fallback: kill_switch)",
            )
        )
        self.assertEqual(block["degrades"], ["kill_switch"])
        self.assertEqual(block["byPhase"]["arrivalInvariance"], "contiguous")

    def test_explicit_paged_resolving_contiguous_is_a_violation(self):
        sweep = make_sweep(selection="paged", resolved="contiguous")
        block = resolve(sweep=sweep)
        self.assertEqual(
            block["postureViolations"], ["--kv-backend paged resolved contiguous"]
        )

    def test_report_without_the_block_is_refused(self):
        sweep = make_sweep()
        del sweep["kvBackend"]
        with self.assertRaisesRegex(RuntimeError, "did not report a kvBackend block"):
            resolve(sweep=sweep)

    def test_phase_without_the_block_is_refused(self):
        # An old binary accepts `--kv-backend` on these modes (the flag is
        # declared on the command) and ignores it. Absent evidence is refused
        # rather than read as agreement.
        scheduler = make_scheduler()
        del scheduler["kvBackend"]
        with self.assertRaisesRegex(
            RuntimeError, "scheduler prefill did not report a kvBackend block"
        ):
            resolve(scheduler=scheduler)

    def test_phase_running_another_selection_is_refused(self):
        # Exactly what an unforwarded flag looks like from the report: the
        # phase ran `auto` while the wrapper asked for paged.
        with self.assertRaisesRegex(
            RuntimeError, r"arrival invariance ran --kv-backend 'auto'"
        ):
            resolve(arrival=make_arrival(selection="auto", resolved="contiguous"))

    def test_phase_that_named_no_backend_at_all_is_a_violation(self):
        # An empty `resolved` list is not agreement: the phase reported the
        # selection and then named no engine, so its numbers belong to no arm.
        scheduler = make_scheduler()
        scheduler["kvBackend"]["resolved"] = []
        block = resolve(scheduler=scheduler)
        self.assertIn("schedulerPrefill resolved no KV backend", block["postureViolations"])
        self.assertNotIn("schedulerPrefill", block["byPhase"])

    def test_cell_without_a_resolved_backend_is_refused(self):
        sweep = make_sweep()
        sweep["decode"][2]["resolvedKVBackend"] = None
        with self.assertRaisesRegex(RuntimeError, "without recording a backend"):
            resolve(sweep=sweep)

    def test_selection_drift_between_wrapper_and_binary_is_refused(self):
        with self.assertRaisesRegex(RuntimeError, "but this wrapper requested"):
            resolve(make_args(kv_backend="contiguous"))

    def test_unknown_kind_is_refused_rather_than_compared(self):
        sweep = make_sweep(resolved_by_batch={1: "quantized-pages"})
        with self.assertRaisesRegex(RuntimeError, "unrecognised KV backend kind"):
            resolve(sweep=sweep)

    def test_degrade_reason_is_carried_not_just_the_kind(self):
        # With paged opt-in, a deliberately paged slot quietly serving
        # contiguous is the failure that matters, and only the reason
        # separates a machine that cannot serve paged from one that was not
        # PACKAGED for it: the preflight resolves its SwiftPM resource bundle
        # relative to the executable, so a bare `cp` of the binary without
        # the `.bundle` disables paged on a perfectly capable box.
        reason = (
            "kernel_preflight: MLXLMCommon resource bundle missing beside the "
            "executable — copy the .bundle alongside the binary"
        )
        block = resolve(sweep=make_sweep(resolved=f"contiguous (fallback: {reason})"))
        self.assertEqual(block["degrades"], [reason])
        # Verbatim in the violation, so the operator reads a packaging fix
        # rather than a hardware verdict.
        self.assertIn(reason, block["postureViolations"][0])

    def test_a_degrade_that_kept_the_kind_is_still_a_violation(self):
        # The kill switch degrades an explicit selection without changing the
        # resolved kind's agreement in every case; a run that was degraded at
        # all did not honour the selection it names.
        sweep = make_sweep(resolved="paged (fallback: DARKBLOOM_CBV2_PAGED_KV=0)")
        block = resolve(sweep=sweep)
        self.assertEqual(
            block["postureViolations"],
            ["--kv-backend paged was degraded: DARKBLOOM_CBV2_PAGED_KV=0"],
        )

    def test_unmeasured_cell_names_the_batch_size_and_the_reason(self):
        # Not the generic "expected positive metric at decode[6]...": each
        # cell builds its own concurrency-sized engine, so a lost B=8 is the
        # most likely and most expensive cell to lose.
        sweep = make_sweep(
            unmeasured=[{"batchSize": 8, "reason": "engine_v2: no KV byte headroom"}]
        )
        with self.assertRaisesRegex(RuntimeError, r"B=8: engine_v2: no KV byte headroom"):
            resolve(sweep=sweep)

    def test_report_without_coverage_is_refused(self):
        sweep = make_sweep()
        del sweep["decodeCoverage"]
        with self.assertRaisesRegex(RuntimeError, "predates schema 4"):
            resolve(sweep=sweep)


class BackendPinTests(unittest.TestCase):
    def setUp(self):
        self.current = resolve()

    def test_matching_backend_compares(self):
        baseline = {"kvBackend": dict(self.current)}
        validate_kv_backend_pin(baseline, self.current)

    def test_contiguous_baseline_refuses_a_paged_run(self):
        baseline = {
            "kvBackend": {
                "selection": "contiguous",
                "resolved": ["contiguous"],
                "byBatchSize": dict.fromkeys(["1", "2", "4", "8"], "contiguous"),
                "byPhase": dict.fromkeys(
                    ["throughputSweep", "schedulerPrefill", "arrivalInvariance"],
                    "contiguous",
                ),
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

    def test_baseline_without_per_phase_backends_refuses(self):
        # A schema-3 baseline recorded its decode curve's backend and nothing
        # about the two phases beside it, which is precisely the run whose
        # prefill and arrival numbers came off the other arm.
        baseline = {"kvBackend": {k: v for k, v in self.current.items() if k != "byPhase"}}
        with self.assertRaisesRegex(RuntimeError, "records no per-phase KV backend"):
            validate_kv_backend_pin(baseline, self.current)

    def test_per_phase_disagreement_refuses_even_when_the_curve_matches(self):
        # Identical decode curves, different prefill engines: every
        # schedulerTTFT delta the report tabulates is cross-population.
        baseline = {"kvBackend": dict(self.current)}
        baseline["kvBackend"]["byPhase"] = dict(
            self.current["byPhase"], schedulerPrefill="contiguous"
        )
        with self.assertRaises(RuntimeError) as caught:
            validate_kv_backend_pin(baseline, self.current)
        self.assertIn(
            "schedulerPrefill: 'paged' (baseline 'contiguous')", str(caught.exception)
        )

    def test_per_cell_disagreement_refuses_even_when_the_set_matches(self):
        # Both runs saw {paged, contiguous}, but on different batch sizes, so
        # every per-batch delta in the report is cross-population.
        mixed = resolve(
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
                "byPhase": dict(mixed["byPhase"]),
            }
        }
        with self.assertRaises(RuntimeError) as caught:
            validate_kv_backend_pin(baseline, mixed)
        message = str(caught.exception)
        self.assertIn("B=1: 'paged' (baseline 'contiguous')", message)
        self.assertIn("B=8: 'contiguous' (baseline 'paged')", message)


class DryRunTests(unittest.TestCase):
    """`main()` end to end with the subprocess boundary replaced."""

    def run_main(
        self,
        args: argparse.Namespace,
        sweep: dict,
        output_dir: Path,
        phase_resolved: str | None = None,
    ) -> int:
        args.output_dir = str(output_dir)
        selection = sweep["kvBackend"]["selection"]
        # The two non-sweep phases now run the same selection; by default they
        # resolve what the sweep's first cell did, and a test that wants a
        # mixed-arm run overrides it.
        resolved = phase_resolved or sweep["decode"][0]["resolvedKVBackend"]
        payloads = {
            "--sweep": sweep,
            "--scheduler-prefill": fixtures.scheduler_payload(
                prefill_lengths=args.prefill_lengths,
                iterations=args.iterations,
                selection=selection,
                resolved=resolved,
            ),
            "--arrival-invariance": fixtures.arrival_payload(
                iterations=args.iterations,
                prompt_tokens=args.arrival_prompt_tokens,
                decode_tokens=args.arrival_decode_tokens,
                selection=selection,
                resolved=resolved,
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
        # The forwarded flags, as actually handed to the binary -- on EVERY
        # command, not just the sweep.
        for command in self.commands:
            self.assertEqual(command[command.index("--kv-backend") + 1], "paged")
        self.assertEqual(
            report["kvBackend"]["byPhase"],
            {
                "throughputSweep": "paged",
                "schedulerPrefill": "paged",
                "arrivalInvariance": "paged",
            },
        )
        sweep_command = next(item for item in self.commands if "--sweep" in item)
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
                "byPhase": dict.fromkeys(
                    ["throughputSweep", "schedulerPrefill", "arrivalInvariance"],
                    "contiguous",
                ),
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

    def test_a_phase_measuring_the_other_backend_fails_the_run(self):
        # End to end: the sweep resolves paged, the two commands beside it
        # resolve contiguous. Before the pin this was the DEFAULT shape of a
        # paged run and nothing in the artifact said so.
        with tempfile.TemporaryDirectory() as directory:
            output_dir = Path(directory)
            status = self.run_main(
                make_args(), make_sweep(), output_dir, phase_resolved="contiguous"
            )
            report = self.latest_report(output_dir)
            markdown = (output_dir / "gemma-contbatch-latest.md").read_text(
                encoding="utf-8"
            )

        self.assertEqual(status, 1)
        self.assertEqual(
            report["kvBackend"]["byPhase"],
            {
                "throughputSweep": "paged",
                "schedulerPrefill": "contiguous",
                "arrivalInvariance": "contiguous",
            },
        )
        self.assertIn("- KV backend posture: FAIL", markdown)
        # Visible in the artifact, not merely inferable from the violation.
        self.assertIn("schedulerPrefill: `contiguous`", markdown)

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
