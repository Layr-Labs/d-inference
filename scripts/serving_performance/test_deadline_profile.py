import json
import unittest

from .deadline_profile import evaluate_deadline_profile
from .matrix import CHECKS, RUNTIME_REVISION
from .test_calibration import receipt as calibration_receipt


def receipt():
    calibration = calibration_receipt()
    for sample in calibration["cells"][0]["samples"]:
        sample.update(engine_decode_tps=60, thermal_state="nominal", power_mode="automatic", retired=True)
    return {"schema_version": 1, "kind": "deadline_only", "identity": {
        "id": "deadline-fixture", "model_id": "fixture", "artifact_sha256": "a" * 64,
        "provider_version": "test", "runtime_revision": RUNTIME_REVISION, "kv_backend": "paged",
        "chip_name": "Apple M5 Max", "gpu_cores": 40, "memory_gb": 128,
        "configured_context_tokens": 262144, "effective_max_concurrency": 4,
        "prefill_chunk_size": 1024, "max_concurrent_partial_prefills": 1,
        "solo_prefill_stripe_tokens": 4096, "mixed_prefill_token_cap": None},
        "build": {"configuration": "release", "dirty": False, "debug_condition": False,
                  "debug_assertions_enabled": False, "build_identity_version": 1,
                  "source_commit": "a" * 40, "sdk_commit": "b" * 40,
                  "source_tree_sha256": "c" * 64, "test_binary_sha256": "d" * 64,
                  "metallib_sha256": "e" * 64},
        "checks": {key: {"passed": True, "receipt_sha256": "f" * 64} for key in CHECKS},
        "deadline_calibration": calibration}


def evaluate(value):
    return evaluate_deadline_profile(json.dumps(value).encode())


class DeadlineProfileTests(unittest.TestCase):
    def test_narrow_cell_retains_full_runtime_context_without_policy(self):
        result = evaluate(receipt())
        self.assertTrue(result["qualified"], result["errors"])
        profile = result["profile"]
        self.assertEqual(profile["configured_context_tokens"], 262144)
        self.assertEqual(profile["deadline_calibration"]["cells"][0]["context_tokens_max"], 4224)
        for field in ("batch_curve", "max_concurrency", "whole_mac_concurrency"):
            self.assertNotIn(field, profile)

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
