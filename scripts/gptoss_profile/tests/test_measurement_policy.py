"""CPU-only measurement policy and common-window interval contracts."""

import unittest

from gptoss_profile.config import instrumentation_controls
from gptoss_profile.summary import decode_intervals
from gptoss_profile.validation import positive, validate


class MeasurementPolicyTests(unittest.TestCase):
    def test_diagnostic_control_names_and_values_preserve_exact_policy(self):
        names = [f"MLX_{kind}_ENABLED" for kind in ("PROFILE", "TRACE", "TIMING", "CAPTURE", "DEBUG")]
        for disabled in ("0", "false", "no", "off", "", "FaLsE", "OFF"):
            self.assertEqual(instrumentation_controls(dict.fromkeys(names, disabled)), [])
        for enabled in ("1", "true", "arbitrary", " off "):
            self.assertEqual(instrumentation_controls(dict.fromkeys(names, enabled)), names)
        self.assertEqual(instrumentation_controls({"MLX_NORMAL": "1", "MLX_trace": "1"}), [])

    def test_scalar_metrics_require_real_positive_finite_numbers(self):
        for value in (True, False, None, "1", 0, -1, float("nan"), float("inf")):
            with self.subTest(value=value):
                self.assertFalse(positive(value))
        for value in (1, 1.0, .25):
            self.assertTrue(positive(value))

    def test_boolean_ttft_cannot_validate_as_a_measurement(self):
        spec = {"cell": {"phase": "prefill", "context": 512}, "iterations": 1,
                "decodeTokens": 64, "backend": "contiguous", "provenanceID": "fixture"}
        manifest = {"modelID": "fixture", "model": {"path": "/tmp/fixture"}, "provenanceID": "fixture"}
        report = {"schemaVersion": 4, "modelID": "fixture", "modelPath": "/tmp/fixture",
                  "kvBackend": {"selection": "contiguous", "resolved": ["contiguous"]},
                  "promptLengths": [512], "samples": [{"promptTokens": 512, "ttftMs": True,
                                                       "resolvedKVBackend": "contiguous"}]}
        with self.assertRaisesRegex(ValueError, "Invalid prefill sample"):
            validate(report, spec, manifest)
        report["samples"][0]["ttftMs"] = 1
        validate(report, spec, manifest)

    def test_intervals_keep_row_order_and_inclusive_overlap_boundaries(self):
        timings = [
            {"rows": [{"tokenArrivalMs": [0, 10, 20, 30]}, {"tokenArrivalMs": [10, 15, 25]}]},
            {"rows": [{"tokenArrivalMs": [100, 105, 120]}]},
        ]
        all_intervals, common = decode_intervals(timings)
        self.assertEqual(all_intervals, [10, 10, 10, 5, 10, 5, 15])
        self.assertEqual(common, [10, 5, 10, 5, 15])
