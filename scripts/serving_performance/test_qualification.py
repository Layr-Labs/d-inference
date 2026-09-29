import copy
import hashlib
import json
import unittest

from serving_performance.evaluate import evaluate
from serving_performance.matrix import CHECKS, MIN_SAMPLES, RUNTIME_REVISION, shapes


def receipt(selected_widths=(1, 2)):
    identity = dict(id="test-profile", model_id="fixture", artifact_sha256="a" * 64,
                    provider_version="test", runtime_revision=RUNTIME_REVISION, kv_backend="contiguous",
                    chip_name="Apple M5 Max", gpu_cores=40, memory_gb=128, context_tokens_max=2048)
    report = dict(schema_version=1, identity=identity, serving_sets=[[], ["other"]], qualification_cells=[])
    for width in selected_widths:
        for prompt, output, arrival, cache, models in shapes(identity, report["serving_sets"]):
            sample = dict(decode_p10_tps=40, aggregate_decode_tps=40 * width, prefill_tps=2000,
                          first_content_p95_ms=1000, token_gap_p95_ms=25, forward_widths=[width],
                          power_mode="automatic", thermal_state="nominal",
                          mtp_active=False, runtime_policy_overrides={}, effective_mixed_prefill_token_cap=None,
                          competing_model_active_requests={model: 1 for model in models},
                          activation_peak_bytes=2**30,
                          kv_peak_bytes=2**30, resident_bytes=10 * 2**30, activation_reserve_bytes=6 * 2**30,
                          memory_budget_bytes=100 * 2**30)
            report["qualification_cells"].append(dict(
                width=width, prompt_tokens=prompt, output_tokens=output, arrival_pattern=arrival,
                cache_state=cache, competing_models=list(models), failures=0,
                raw_measurements_sha256="b" * 64, absolute_first_content_budget_ms=5000,
                resolved_activation_floor_bytes=5.5 * 2**30,
                checks={check: dict(passed=True, receipt_sha256="c" * 64) for check in CHECKS},
                samples=[dict(sample, run_id=str(i)) for i in range(MIN_SAMPLES)]))
    return report


def chunk_receipt(cap=128):
    report = receipt()
    report["mixed_prefill_token_cap"] = cap
    for cell in report["qualification_cells"]:
        baseline = {key: cell["samples"][0][key] for key in
                    ("decode_p10_tps", "aggregate_decode_tps", "prefill_tps", "first_content_p95_ms")}
        cell["mixed_prefill_baseline"] = dict(
            baseline, token_gap_p95_ms=40, receipt_sha256="d" * 64,
            effective_mixed_prefill_token_cap=None)
        cell["mixed_prefill_work_p95_ms"] = 90
        for sample in cell["samples"]:
            sample["effective_mixed_prefill_token_cap"] = cap
    return report


def run(report):
    return evaluate(json.dumps(report).encode())


class QualificationTests(unittest.TestCase):
    def test_mtp_identity_requires_actual_drafting_with_exact_configuration(self):
        report = receipt((1,))
        mtp = dict(enabled=True, artifact_sha256="d" * 64, max_draft_tokens=4,
                   max_speculative_batch=4, verification_mode="automatic", max_automatic_rectangular_tokens=4)
        report["identity"]["mtp"] = mtp
        for cell in report["qualification_cells"]:
            for sample in cell["samples"]:
                sample.update(mtp_active=True, mtp=copy.deepcopy(mtp), mtp_rounds=20, mtp_proposed_tokens=60)
        self.assertTrue(run(report)["qualified"])
        report["qualification_cells"][0]["samples"][0]["mtp_proposed_tokens"] = 0
        self.assertFalse(run(report)["qualified"])

    def test_new_receipt_requires_held_out_calibration_and_copies_only_derived_cell(self):
        from serving_performance.test_calibration import receipt as calibration_receipt
        report = receipt((1,))
        report["schema_version"] = 2
        self.assertFalse(run(report)["qualified"])
        calibration = calibration_receipt()
        cell = calibration["cells"][0]
        cell.update(prompt_tokens_min=1024, prompt_tokens_max=1024,
                    context_tokens_min=1152, context_tokens_max=1152, max_prefill_work_tokens=1024)
        for sample in cell["samples"]:
            sample.update(prompt_tokens=1024, context_tokens=1152, prefill_work_tokens=1024)
        report["deadline_calibration"] = calibration
        result = run(report)
        self.assertTrue(result["qualified"], result["errors"])
        derived = result["profile"]["deadline_calibration"]["cells"][0]
        self.assertNotIn("samples", derived)
        self.assertEqual(derived["report_sha256"], result["receipt_sha256"])

    def test_identity_cannot_inject_qualification_results_or_runtime_policy(self):
        injected = {
            "mixed_prefill_token_cap": 512,
            "max_concurrency": 16,
            "whole_mac_concurrency": 16,
            "batch_curve": [{"width": 16, "decode_p10_tps": 1000}],
            "qualification_report_sha256": "f" * 64,
            "unreviewed_policy": {"enabled": True},
        }
        for selected_widths in ((1,), (1, 2)):
            for field, value in injected.items():
                with self.subTest(widths=selected_widths, field=field):
                    report = receipt(selected_widths)
                    self.assertTrue(run(report)["qualified"])
                    report["identity"][field] = value
                    result = run(report)
                    self.assertFalse(result["qualified"])
                    self.assertIsNone(result["profile"])
                    self.assertIn(f"identity.{field} is not a supported identity field", result["errors"])

    def test_profile_contains_only_identity_and_evaluated_results(self):
        identity_fields = {
            "id", "model_id", "artifact_sha256", "provider_version", "runtime_revision",
            "kv_backend", "chip_name", "gpu_cores", "memory_gb", "context_tokens_max",
        }
        derived_fields = {
            "max_concurrency", "whole_mac_concurrency", "qualification_report_sha256", "batch_curve",
        }
        for mixed in (False, True):
            for limit in (1, 2):
                with self.subTest(mixed=mixed, limit=limit):
                    report = chunk_receipt() if mixed else receipt()
                    report["qualification_cells"] = [
                        cell for cell in report["qualification_cells"] if cell["width"] <= limit]
                    profile = run(report)["profile"]
                    fields = identity_fields | derived_fields
                    if mixed and limit > 1:
                        fields |= {"mixed_prefill_token_cap"}
                        self.assertEqual(profile["mixed_prefill_token_cap"], 128)
                    self.assertEqual(set(profile), fields)
                    self.assertEqual(profile["max_concurrency"], limit)

    def test_only_complete_passing_widths_promote(self):
        report = receipt()
        result = run(report)
        self.assertTrue(result["qualified"])
        self.assertEqual(result["profile"]["max_concurrency"], 2)
        self.assertEqual(result["profile"]["whole_mac_concurrency"], 2)
        self.assertEqual(result["profile"]["qualification_report_sha256"],
                         hashlib.sha256(json.dumps(report).encode()).hexdigest())
        self.assertFalse(result["widths"][2]["qualified"])

    def test_missing_baseline_cannot_be_bypassed_by_larger_width(self):
        report = receipt()
        report["qualification_cells"].pop(0)
        self.assertFalse(run(report)["qualified"])

    def test_higher_width_cannot_skip_a_missing_or_failed_required_width(self):
        for blocked_width, last_passing in ((2, 1), (6, 4)):
            for failure in ("missing", "failed"):
                with self.subTest(blocked_width=blocked_width, failure=failure):
                    report = receipt((1, 2, 4, 6, 8))
                    self.assertEqual(run(report)["profile"]["max_concurrency"], 8)
                    if failure == "missing":
                        report["qualification_cells"] = [
                            cell for cell in report["qualification_cells"] if cell["width"] != blocked_width]
                    else:
                        next(cell for cell in report["qualification_cells"]
                             if cell["width"] == blocked_width)["failures"] = 1
                    result = run(report)
                    self.assertEqual(result["profile"]["max_concurrency"], last_passing)
                    for width in result["widths"]:
                        if width["width"] > blocked_width:
                            self.assertFalse(width["qualified"])
                            self.assertIn(f"lower required width {blocked_width} did not qualify", width["errors"])

    def test_failed_wider_cell_keeps_lower_profile(self):
        for mutation in (
            lambda c: c.update(failures=1),
            lambda c: c["checks"].pop("cancellation"),
            lambda c: c["samples"][0].update(forward_widths=[1]),
            lambda c: c["samples"][0].update(thermal_state="serious"),
            lambda c: c["samples"][0].update(mtp_active=True),
            lambda c: c["samples"][0].pop("mtp_active"),
            lambda c: c["samples"][0].update(runtime_policy_overrides={"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "512"}),
            lambda c: c["samples"][0].update(aggregate_decode_tps=42),
            lambda c: c["samples"][0].update(first_content_p95_ms=3500),
            lambda c: c["samples"][0].update(decode_p10_tps=29),
            lambda c: c["samples"][0].update(activation_peak_bytes=8 * 2**30),
            lambda c: c["samples"].pop(),
        ):
            report = receipt()
            mutation(next(c for c in report["qualification_cells"] if c["width"] == 2))
            self.assertEqual(run(report)["profile"]["max_concurrency"], 1)

    def test_same_shape_regression_is_not_hidden_by_other_cells(self):
        report = receipt()
        cell = next(c for c in report["qualification_cells"] if c["width"] == 2)
        for sample in cell["samples"]:
            sample["aggregate_decode_tps"] = 41
        self.assertEqual(run(report)["profile"]["max_concurrency"], 1)

    def test_nonfinite_rates_and_unrun_checks_fail_closed(self):
        for metric in (float("nan"), float("inf"), -1, True):
            report = receipt()
            report["qualification_cells"][0]["samples"][0]["prefill_tps"] = metric
            self.assertFalse(run(report)["qualified"])
        report = receipt()
        report["qualification_cells"][0]["checks"]["isolation"]["passed"] = "true"
        self.assertFalse(run(report)["qualified"])

    def test_duplicate_or_incomplete_serving_set_is_rejected(self):
        report = receipt()
        report["qualification_cells"].append(copy.deepcopy(report["qualification_cells"][0]))
        self.assertFalse(run(report)["qualified"])
        report = receipt()
        report["serving_sets"] = [[]]
        self.assertFalse(run(report)["qualified"])

    def test_target_model_cannot_supply_its_own_competing_model_evidence(self):
        report = receipt()
        target = report["identity"]["model_id"]
        report["serving_sets"] = [[], [target]]
        for cell in report["qualification_cells"]:
            if cell["competing_models"]:
                cell["competing_models"] = [target]
                for sample in cell["samples"]:
                    sample["competing_model_active_requests"] = {target: 1}
        result = run(report)
        self.assertFalse(result["qualified"])
        self.assertIsNone(result["profile"])
        self.assertIn("serving_sets cannot use the target model as a competing model", result["errors"])

    def test_large_context_requires_boundary_measurement(self):
        report = receipt()
        report["identity"]["context_tokens_max"] = 131072
        required = shapes(report["identity"], report["serving_sets"])
        self.assertTrue(any(s[0] + s[1] == 131072 for s in required))
        self.assertFalse(run(report)["qualified"])

    def test_every_configured_context_requires_its_boundary(self):
        for context in (2048, 4096, 16384, 32768, 131072):
            report = receipt()
            report["identity"]["context_tokens_max"] = context
            required = shapes(report["identity"], report["serving_sets"])
            self.assertTrue(any(s[0] + s[1] == context for s in required))

    def test_resident_but_idle_models_do_not_certify_competing_work(self):
        report = receipt()
        cell = next(c for c in report["qualification_cells"] if c["competing_models"])
        cell["samples"][0]["competing_model_active_requests"] = {"other": 0}
        self.assertFalse(run(report)["qualified"])

    def test_malformed_check_evidence_is_not_a_passing_claim(self):
        report = receipt()
        report["qualification_cells"][0]["checks"] = None
        self.assertFalse(run(report)["qualified"])

    def test_chunk_promotion_needs_measured_comparison(self):
        report = chunk_receipt()
        for cell in report["qualification_cells"]:
            cell.pop("mixed_prefill_baseline")
        unqualified_chunk = run(report)["profile"]
        self.assertEqual(unqualified_chunk["max_concurrency"], 1)
        self.assertNotIn("mixed_prefill_token_cap", unqualified_chunk)
        self.assertEqual(run(chunk_receipt())["profile"]["max_concurrency"], 2)

    def test_chunk_candidate_must_match_every_observed_sample(self):
        for invalid in (None, 256, "128", 128.0, True):
            with self.subTest(invalid=invalid):
                report = chunk_receipt()
                report["qualification_cells"][0]["samples"][0]["effective_mixed_prefill_token_cap"] = invalid
                self.assertFalse(run(report)["qualified"])
        report = chunk_receipt()
        report["qualification_cells"][0]["samples"][0].pop("effective_mixed_prefill_token_cap")
        self.assertFalse(run(report)["qualified"])
        report = chunk_receipt()
        report["mixed_prefill_token_cap"] = 256
        self.assertFalse(run(report)["qualified"])
        report = chunk_receipt()
        report.pop("mixed_prefill_token_cap")
        self.assertFalse(run(report)["qualified"])

    def test_candidate_allows_only_its_exact_global_override(self):
        report = chunk_receipt()
        for cell in report["qualification_cells"]:
            for sample in cell["samples"]:
                sample["runtime_policy_overrides"] = {"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "128"}
        self.assertEqual(run(report)["profile"]["mixed_prefill_token_cap"], 128)
        for overrides in (
            {"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "256"},
            {"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": 128},
            {"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "128", "DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE": "2048"},
            {"DARKBLOOM_CBV2_MIXED_PREFILL_CAP_BY_MODEL": "fixture=128"},
        ):
            with self.subTest(overrides=overrides):
                invalid = copy.deepcopy(report)
                invalid["qualification_cells"][0]["samples"][0]["runtime_policy_overrides"] = overrides
                self.assertFalse(run(invalid)["qualified"])
        plain = receipt()
        plain["qualification_cells"][0]["samples"][0]["runtime_policy_overrides"] = {
            "DARKBLOOM_CBV2_MIXED_PREFILL_CAP": "128"}
        self.assertFalse(run(plain)["qualified"])

    def test_baseline_requires_an_explicit_different_measured_policy(self):
        for invalid in (128, "256", -1, True):
            with self.subTest(invalid=invalid):
                report = chunk_receipt()
                cell = next(c for c in report["qualification_cells"]
                            if c["width"] == 2 and c["arrival_pattern"] == "staggered")
                cell["mixed_prefill_baseline"]["effective_mixed_prefill_token_cap"] = invalid
                self.assertEqual(run(report)["profile"]["max_concurrency"], 1)
        report = chunk_receipt()
        cell = next(c for c in report["qualification_cells"]
                    if c["width"] == 2 and c["arrival_pattern"] == "staggered")
        cell["mixed_prefill_baseline"].pop("effective_mixed_prefill_token_cap")
        self.assertEqual(run(report)["profile"]["max_concurrency"], 1)
        report = chunk_receipt()
        for cell in report["qualification_cells"]:
            cell["mixed_prefill_baseline"]["effective_mixed_prefill_token_cap"] = 256
        self.assertEqual(run(report)["profile"]["max_concurrency"], 2)


if __name__ == "__main__":
    unittest.main()
