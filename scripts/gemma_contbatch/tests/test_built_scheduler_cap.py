"""A requested width must never label a smaller constructed scheduler."""

import unittest

from ..validation import validate_raw_outputs
from .test_gemma_optimizations import raw_outputs
from .test_kv_backend import make_args


class BuiltSchedulerCapTests(unittest.TestCase):
    def test_current_reports_require_exact_integer_caps(self):
        for phase in ("throughputSweep", "arrivalInvariance"):
            for invalid in (None, 0, 8, 16, "4", 4.0, True):
                with self.subTest(phase=phase, invalid=invalid):
                    outputs = raw_outputs()
                    sample = outputs[phase]["decode"][0] if phase == "throughputSweep" else outputs[phase]
                    sample["effectiveMaxConcurrentRequests"] = invalid
                    with self.assertRaisesRegex(RuntimeError, "built scheduler cap"):
                        validate_raw_outputs(make_args(), *outputs.values())

    def test_current_reports_with_exact_caps_pass(self):
        validate_raw_outputs(make_args(), *raw_outputs().values())
