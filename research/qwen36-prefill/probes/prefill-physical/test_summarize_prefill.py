#!/usr/bin/env python3

from __future__ import annotations

import json
import unittest

import summarize_prefill


class PrefillSummaryTests(unittest.TestCase):
    def test_summarizes_strict_burst_report(self) -> None:
        report = {
            "schemaVersion": 6,
            "modelID": "qwen-test",
            "batchSize": 2,
            "promptTokensPerRequest": 8192,
            "iterations": 2,
            "kvBackend": {"resolved": ["contiguous"]},
            "patterns": [
                {
                    "name": "burst",
                    "medianAggregatePrefillTokensPerSecond": 1700.5,
                    "medianPrefillMakespanMs": 9600.25,
                    "medianTTFTMs": 9599.5,
                    "arrivalWithinTolerance": True,
                    "outputsStableAcrossIterations": True,
                    "firstTokensStableAcrossIterations": True,
                    "samples": [
                        {
                            "aggregatePrefillTokensPerSecond": 1699.0,
                            "prefillMakespanMs": 9601.0,
                        },
                        {
                            "aggregatePrefillTokensPerSecond": 1702.0,
                            "prefillMakespanMs": 9598.0,
                        },
                    ],
                }
            ],
        }

        lines = summarize_prefill.summarize(report)

        self.assertEqual(
            lines[0],
            "PREFILL_REPORT schema=6 model=qwen-test batch=2"
            " prompt_tokens_per_request=8192 requested_prompt_tokens=16384"
            " iterations=2 kv_backend=contiguous prefix_cache=off"
            " numerical_posture=strict_default_top8",
        )
        self.assertIn("name=burst median_aggregate_tps=1700.500", lines[1])
        self.assertIn("min_sample_tps=1699.000 max_sample_tps=1702.000", lines[1])
        self.assertIn("outputs_stable=true first_tokens_stable=true", lines[1])

    def test_rejects_non_contiguous_report(self) -> None:
        report = {
            "schemaVersion": 6,
            "modelID": "qwen-test",
            "batchSize": 1,
            "promptTokensPerRequest": 8192,
            "iterations": 1,
            "kvBackend": {"resolved": ["paged"]},
            "patterns": [{"name": "burst"}],
        }

        with self.assertRaisesRegex(ValueError, "expected contiguous KV"):
            summarize_prefill.summarize(report)

    def test_extracts_report_after_xctrace_progress_output(self) -> None:
        report = {
            "schemaVersion": 6,
            "patterns": [],
        }
        mixed = (
            "gemma optimizations: prefill_layer18=on\n"
            "[arrival-invariance] loading model\n"
            + json.dumps(report)
            + "\n"
        )

        self.assertEqual(summarize_prefill.extract_report(mixed), report)

    def test_rejects_output_without_report(self) -> None:
        with self.assertRaisesRegex(ValueError, "contains no benchmark JSON"):
            summarize_prefill.extract_report("benchmark did not finish\n")


if __name__ == "__main__":
    unittest.main()
