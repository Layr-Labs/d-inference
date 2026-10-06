import json
import unittest

from .deadline_profile import evaluate_deadline_profile
from .check_receipt_fixtures import ROOT as EVIDENCE_ROOT
from .posture import COOLED_DEADLINE_APPLICABILITY
from .deadline_receipt_fixtures import receipt


def evaluate(value):
    return evaluate_deadline_profile(json.dumps(value).encode(), evidence_root=EVIDENCE_ROOT)


class DeadlineProfileTests(unittest.TestCase):
    def test_narrow_cell_retains_full_runtime_context_without_policy(self):
        result = evaluate(receipt())
        self.assertTrue(result["qualified"], result["errors"])
        profile = result["profile"]
        self.assertEqual(profile["configured_context_tokens"], 262144)
        self.assertEqual(profile["deadline_calibration"]["cells"][0]["context_tokens_max"], 4129)
        for field, value in COOLED_DEADLINE_APPLICABILITY.items():
            self.assertEqual(profile[field], value)
        for field in ("batch_curve", "max_concurrency", "whole_mac_concurrency"):
            self.assertNotIn(field, profile)

    def test_cooled_evidence_cannot_certify_general_nominal_start_admission(self):
        for policy in (None, {},
                       dict(COOLED_DEADLINE_APPLICABILITY, minimum_whole_mac_quiescence_ms=0),
                       dict(COOLED_DEADLINE_APPLICABILITY, minimum_nominal_stability_ms=0),
                       dict(COOLED_DEADLINE_APPLICABILITY, minimum_nominal_stability_ms=5000.0),
                       dict(COOLED_DEADLINE_APPLICABILITY, power_mode="high")):
            value = receipt()
            value["applicability"] = policy
            result = evaluate(value)
            with self.subTest(policy=policy):
                self.assertFalse(result["qualified"])
                self.assertIsNone(result["profile"])

    def test_cannot_smuggle_universal_policy(self):
        for field in ("batch_curve", "max_concurrency", "whole_mac_concurrency", "context_tokens_max"):
            value = receipt()
            value["identity"][field] = 8
            self.assertFalse(evaluate(value)["qualified"])

    def test_actual_scheduler_fields_and_clean_optimized_build_required(self):
        for field, replacement in (("effective_max_concurrency", 0), ("prefill_chunk_size", 0),
                                   ("max_concurrent_partial_prefills", 2), ("max_concurrent_partial_prefills", True),
                                   ("mixed_prefill_token_cap", 1024), ("solo_prefill_stripe_tokens", 0)):
            value = receipt()
            value["identity"][field] = replacement
            self.assertFalse(evaluate(value)["qualified"])
        for field, replacement in (("dirty", True), ("configuration", "debug"), ("debug_condition", True),
                                   ("source_commit", "a" * 8), ("metallib_sha256", None)):
            value = receipt()
            value["build"][field] = replacement
            self.assertFalse(evaluate(value)["qualified"])

    def test_missing_lifecycle_decode_floor_and_posture_fail_closed(self):
        for case in ("lifecycle", "decode", "thermal", "retirement", "mtp"):
            value = receipt()
            if case == "lifecycle":
                value["checks"].pop("cancellation")
            else:
                for sample in value["deadline_calibration"]["cells"][0]["samples"]:
                    sample.update({"decode": {"engine_decode_tps": 29.9}, "thermal": {"thermal_state": "serious"},
                                   "retirement": {"retired": False}, "mtp": {"mtp": {"enabled": True}}}[case])
            self.assertFalse(evaluate(value)["qualified"])

    def test_failed_holdout_cannot_promote_narrow_profile(self):
        value = receipt()
        value["deadline_calibration"]["cells"][0]["samples"][-1]["observed_first_content_ms"] = 90_000
        result = evaluate(value)
        self.assertFalse(result["qualified"])
        self.assertIsNone(result["profile"])


if __name__ == "__main__":
    unittest.main()
