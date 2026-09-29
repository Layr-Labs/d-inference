import hashlib
import math
import unittest

from .calibration import evaluate_calibration
from .calibration_statistics import coverage_lower_bound, fit_upper_bound


def receipt(validation_count=59):
    cell = dict(prompt_tokens_min=4096, prompt_tokens_max=4096,
                context_tokens_min=4224, context_tokens_max=4224,
                cache_state="cold", contention="isolated", prefill_tps=1000, decode_tps=40,
                max_prefill_work_tokens=4096, max_decode_work_tokens=33, max_active_requests=1,
                competitor_profile_ids=[], max_other_model_requests=0, max_other_model_service_fraction=0)
    cell["samples"] = []
    for partition, count in (("calibration", 20), ("validation", validation_count)):
        for index in range(count):
            run = f"{partition}-{index}"
            cell["samples"].append(dict(
                partition=partition, run_id=run, request_id=run,
                raw_receipt_sha256=hashlib.sha256(run.encode()).hexdigest(),
                workload_sha256=hashlib.sha256((run + "-prompt").encode()).hexdigest(),
                prompt_tokens=4096, context_tokens=4224, cache_state="cold", contention="isolated",
                prefill_work_tokens=4096, decode_work_tokens=33, active_requests=1,
                competitor_profile_ids=[], other_model_requests=0, other_model_service_fraction=0,
                tool_history=index % 2 == 0, observed_first_content_ms=5100 if partition == "calibration" else 5000))
    return dict(version=1, prompt_contract_id="b" * 64, cells=[cell])


class CalibrationTests(unittest.TestCase):
    def evaluate(self, value):
        return evaluate_calibration(value, "a" * 64, 32768)

    def test_independent_validation_qualifies_exact_wire_cell(self):
        result = self.evaluate(receipt())
        self.assertTrue(result["qualified"], result["errors"])
        cell = result["calibration"]["cells"][0]
        self.assertEqual(cell["calibration_sample_count"], 20)
        self.assertEqual(cell["validation_sample_count"], 59)
        self.assertEqual(cell["validation_covered_count"], 59)
        self.assertGreaterEqual(result["cells"][0]["coverage_lower_bound"], .95)
        self.assertNotIn("samples", cell)

    def test_validation_never_refits_training_margin(self):
        value = receipt()
        original = self.evaluate(value)["cells"][0]["candidate"]
        value["cells"][0]["samples"][-1]["observed_first_content_ms"] = 50_000
        result = self.evaluate(value)
        self.assertFalse(result["qualified"])
        changed = result["cells"][0]["candidate"]
        self.assertEqual(original["error_ratio"], changed["error_ratio"])
        self.assertEqual(original["error_additive_ms"], changed["error_additive_ms"])
        self.assertEqual(changed["validation_covered_count"], 58)

    def test_twenty_perfect_trials_do_not_claim_95_percent_confidence(self):
        result = self.evaluate(receipt(validation_count=20))
        self.assertFalse(result["qualified"])
        self.assertAlmostEqual(result["cells"][0]["coverage_lower_bound"], .05 ** (1 / 20), places=10)

    def test_evidence_only_flag_cannot_bypass_promotion(self):
        value = receipt()
        value["require_confidence_bound"] = False
        result = self.evaluate(value)
        self.assertFalse(result["qualified"])
        self.assertIsNone(result["calibration"])

    def test_repeated_prompt_or_run_cannot_inflate_coverage(self):
        for field in ("run_id", "workload_sha256"):
            with self.subTest(field=field):
                value = receipt()
                samples = value["cells"][0]["samples"]
                samples[-1][field] = samples[-2][field]
                self.assertFalse(self.evaluate(value)["qualified"])

    def test_validation_and_training_cannot_share_run_or_prompt(self):
        for field in ("run_id", "workload_sha256"):
            with self.subTest(field=field):
                value = receipt()
                samples = value["cells"][0]["samples"]
                samples[-1][field] = samples[0][field]
                self.assertFalse(self.evaluate(value)["qualified"])

    def test_censored_refusal_is_visible_and_disqualifies(self):
        value = receipt()
        sample = value["cells"][0]["samples"][-1]
        sample.pop("observed_first_content_ms")
        sample["censored_after_ms"] = 15_000
        result = self.evaluate(value)
        self.assertFalse(result["qualified"])
        self.assertTrue(any("censored/refused" in error for error in result["errors"]))

    def test_unmeasured_scheduler_and_context_bounds_fail(self):
        for field in ("max_prefill_work_tokens", "max_decode_work_tokens", "context_tokens_max"):
            with self.subTest(field=field):
                value = receipt()
                value["cells"][0][field] += 1
                self.assertFalse(self.evaluate(value)["qualified"])

    def test_other_model_requires_exact_nonempty_profile_set(self):
        value = receipt()
        value["cells"][0]["contention"] = "other_model"
        self.assertFalse(self.evaluate(value)["qualified"])

    def test_invalid_numbers_and_tool_coverage_fail_closed(self):
        for change in ({"prefill_tps": math.nan}, {"decode_tps": True}):
            value = receipt()
            value["cells"][0].update(change)
            self.assertFalse(self.evaluate(value)["qualified"])
        value = receipt()
        for sample in value["cells"][0]["samples"]:
            sample["tool_history"] = False
        self.assertFalse(self.evaluate(value)["qualified"])

    def test_fit_uses_measured_additive_and_slope(self):
        ratio, additive = fit_upper_bound([(100, 150), (200, 250), (400, 450)])
        self.assertAlmostEqual(ratio, 1)
        self.assertAlmostEqual(additive, 50)
        ratio, additive = fit_upper_bound([(100, 200), (200, 400), (400, 800)])
        self.assertAlmostEqual(ratio, 2)
        self.assertAlmostEqual(additive, 0)

    def test_confidence_bounds_are_monotonic(self):
        self.assertEqual(coverage_lower_bound(0, 20), 0)
        self.assertLess(coverage_lower_bound(58, 59), coverage_lower_bound(59, 59))
        self.assertLess(coverage_lower_bound(20, 20), coverage_lower_bound(59, 59))


if __name__ == "__main__":
    unittest.main()
