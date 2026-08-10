"""Gemma config provenance must survive every subprocess boundary."""

from __future__ import annotations

import copy
import tempfile
import unittest
from pathlib import Path

from .. import runner
from ..baseline import validate_artifact_pin, validate_configuration_pin
from ..gemma_optimizations import resolve_gemma_optimizations
from ..validation import validate_raw_outputs
from . import fixtures
from .test_kv_backend import make_args, make_arrival, make_scheduler, make_sweep


def raw_outputs() -> dict[str, dict]:
    return {
        "throughputSweep": make_sweep(),
        "schedulerPrefill": make_scheduler(),
        "arrivalInvariance": make_arrival(),
    }


def baseline_configuration(args) -> dict:
    return {
        "iterations": args.iterations,
        "decodeIterations": args.iterations,
        "decodePromptTokens": args.decode_prompt_tokens,
        "decodeTokens": args.decode_tokens,
        "arrivalPromptTokens": args.arrival_prompt_tokens,
        "arrivalDecodeTokens": args.arrival_decode_tokens,
        "batchSizes": args.batch_sizes,
        "prefillLengths": args.prefill_lengths,
        "gemmaOptimizations": copy.deepcopy(fixtures.GEMMA_OPTIMIZATIONS),
    }


def opposite_gemma_optimizations() -> dict:
    settings = copy.deepcopy(fixtures.GEMMA_OPTIMIZATIONS)
    settings["prefillLayer18"] = False
    settings["environment"]["DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL"] = "0"
    return settings


class GemmaOptimizationProvenanceTests(unittest.TestCase):
    def test_matching_effective_settings_are_resolved(self):
        self.assertEqual(
            resolve_gemma_optimizations(raw_outputs()), fixtures.GEMMA_OPTIMIZATIONS
        )

    def test_phase_mismatch_is_refused(self):
        outputs = raw_outputs()
        outputs["arrivalInvariance"]["gemmaOptimizations"] = {
            "prefillLayer18": False,
            "weightedR1": True,
            "environment": {
                **fixtures.GEMMA_OPTIMIZATIONS["environment"],
                "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "0",
            },
        }
        with self.assertRaisesRegex(RuntimeError, "different Gemma optimizations"):
            resolve_gemma_optimizations(outputs)

    def test_partial_weighted_projection_is_refused(self):
        outputs = raw_outputs()
        outputs["throughputSweep"]["gemmaOptimizations"]["environment"][
            "MLX_GATHER_QMM_EXPERT_SLICES"
        ] = "0"
        with self.assertRaisesRegex(RuntimeError, "projection does not match"):
            resolve_gemma_optimizations(outputs)

    def test_stale_raw_schema_is_refused(self):
        outputs = raw_outputs()
        outputs["throughputSweep"]["schemaVersion"] = 4
        with self.assertRaisesRegex(RuntimeError, "schemaVersion is 4, expected 5"):
            validate_raw_outputs(
                make_args(),
                outputs["throughputSweep"],
                outputs["schedulerPrefill"],
                outputs["arrivalInvariance"],
            )

    def test_explicit_config_is_forwarded_to_every_phase_prefix(self):
        args = make_args(config="/tmp/gemma-off.toml")
        prefix = runner.benchmark_argv(Path("/tmp/darkbloom"), args)
        self.assertEqual(
            prefix,
            [
                "/tmp/darkbloom",
                "benchmark",
                "--config",
                "/tmp/gemma-off.toml",
                "--model",
                fixtures.MODEL_ID,
            ],
        )
        for make_command in (runner.sweep_argv, runner.scheduler_argv, runner.arrival_argv):
            self.assertEqual(make_command(prefix, args)[: len(prefix)], prefix)

    def test_relative_config_is_normalized_from_repo_root(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "configs/off.toml"
            config.parent.mkdir()
            config.write_text("[gemma_optimizations]\nweighted_r1 = false\n")
            self.assertEqual(
                runner.resolve_config_path("configs/off.toml", root), str(config.resolve())
            )

    def test_missing_explicit_config_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "not readable"):
                runner.resolve_config_path("missing.toml", Path(directory))

    def test_baseline_with_different_effective_settings_is_refused(self):
        args = make_args()
        configuration = baseline_configuration(args)
        configuration["gemmaOptimizations"] = opposite_gemma_optimizations()
        baseline = {"configuration": configuration}
        with self.assertRaisesRegex(RuntimeError, "gemmaOptimizations"):
            validate_configuration_pin(args, baseline, fixtures.GEMMA_OPTIMIZATIONS)

    def test_gemma_axis_requires_different_settings(self):
        args = make_args(comparison_axis="gemma-optimizations")
        baseline = {"configuration": baseline_configuration(args)}
        with self.assertRaisesRegex(RuntimeError, "requires different"):
            validate_configuration_pin(
                args,
                baseline,
                fixtures.GEMMA_OPTIMIZATIONS,
                comparison_axis=args.comparison_axis,
            )

        validate_configuration_pin(
            args,
            baseline,
            opposite_gemma_optimizations(),
            comparison_axis=args.comparison_axis,
        )

    def test_gemma_axis_refuses_absent_baseline_provenance(self):
        args = make_args(comparison_axis="gemma-optimizations")
        configuration = baseline_configuration(args)
        del configuration["gemmaOptimizations"]
        with self.assertRaisesRegex(
            RuntimeError, "baseline configuration did not report effective"
        ):
            validate_configuration_pin(
                args,
                {"configuration": configuration},
                opposite_gemma_optimizations(),
                comparison_axis=args.comparison_axis,
            )

    def test_gemma_axis_refuses_malformed_baseline_provenance(self):
        args = make_args(comparison_axis="gemma-optimizations")
        configuration = baseline_configuration(args)
        configuration["gemmaOptimizations"]["weightedR1"] = "on"
        with self.assertRaisesRegex(
            RuntimeError, "baseline configuration reported malformed"
        ):
            validate_configuration_pin(
                args,
                {"configuration": configuration},
                opposite_gemma_optimizations(),
                comparison_axis=args.comparison_axis,
            )

    def test_gemma_axis_refuses_partial_baseline_provenance(self):
        args = make_args(comparison_axis="gemma-optimizations")
        configuration = baseline_configuration(args)
        del configuration["gemmaOptimizations"]["environment"][
            "MLX_GATHER_QMM_EXPERT_SLICES"
        ]
        with self.assertRaisesRegex(RuntimeError, "environment projection"):
            validate_configuration_pin(
                args,
                {"configuration": configuration},
                opposite_gemma_optimizations(),
                comparison_axis=args.comparison_axis,
            )

    def test_baseline_iterations_mismatch_is_refused(self):
        args = make_args()
        configuration = baseline_configuration(args)
        configuration["iterations"] += 1
        with self.assertRaisesRegex(RuntimeError, "iterations"):
            validate_configuration_pin(
                args, {"configuration": configuration}, fixtures.GEMMA_OPTIMIZATIONS
            )

    def test_baseline_decode_iterations_mismatch_is_refused(self):
        args = make_args()
        configuration = baseline_configuration(args)
        configuration["decodeIterations"] += 1
        with self.assertRaisesRegex(RuntimeError, "decodeIterations"):
            validate_configuration_pin(
                args, {"configuration": configuration}, fixtures.GEMMA_OPTIMIZATIONS
            )

    def test_gemma_axis_requires_identical_binary_and_metallib(self):
        baseline = {
            "metadata": {"binarySha256": "binary-a", "metallibSha256": "metal"}
        }
        with self.assertRaisesRegex(RuntimeError, "identical artifacts"):
            validate_artifact_pin(
                baseline, {"binarySha256": "binary-b", "metallibSha256": "metal"}
            )


if __name__ == "__main__":
    unittest.main()
