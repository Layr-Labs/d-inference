import copy
import hashlib
import json
import unittest

from serving_performance.evaluate import evaluate
from serving_performance.matrix import CHECKS, MIN_SAMPLES, RUNTIME_REVISION, shapes


def receipt():
    identity = dict(id="test-profile", model_id="fixture", artifact_sha256="a" * 64,
                    provider_version="test", runtime_revision=RUNTIME_REVISION, kv_backend="contiguous",
                    chip_name="Apple M5 Max", gpu_cores=40, memory_gb=128, context_tokens_max=2048)
    report = dict(schema_version=1, identity=identity, serving_sets=[[], ["other"]], qualification_cells=[])
    for width in (1, 2):
        for prompt, output, arrival, cache, models in shapes(identity, report["serving_sets"]):
            sample = dict(decode_p10_tps=40, aggregate_decode_tps=40 * width, prefill_tps=2000,
                          first_content_p95_ms=1000, token_gap_p95_ms=25, forward_widths=[width],
                          power_mode="automatic", thermal_state="nominal",
                          mtp_active=False, runtime_policy_overrides={},
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


def run(report):
    return evaluate(json.dumps(report).encode())


class QualificationTests(unittest.TestCase):
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
        report = receipt()
        report["mixed_prefill_token_cap"] = 128
        unqualified_chunk = run(report)["profile"]
        self.assertEqual(unqualified_chunk["max_concurrency"], 1)
        self.assertNotIn("mixed_prefill_token_cap", unqualified_chunk)
        for cell in report["qualification_cells"]:
            baseline = {key: cell["samples"][0][key] for key in
                        ("decode_p10_tps", "aggregate_decode_tps", "prefill_tps", "first_content_p95_ms")}
            cell["mixed_prefill_baseline"] = dict(baseline, token_gap_p95_ms=40, receipt_sha256="d" * 64)
            cell["mixed_prefill_work_p95_ms"] = 90
        self.assertEqual(run(report)["profile"]["max_concurrency"], 2)


if __name__ == "__main__":
    unittest.main()
