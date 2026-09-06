import copy
import unittest

from compare_radix_engine import compare, mismatch


class TokenEvidenceTests(unittest.TestCase):
    def fixture(self):
        row = {"id": "repeat", "kind": "repeat", "prompt_token_ids": [1] * 5000,
               "token_ids": [12, 13], "text": "answer", "finish": "length",
               "prompt_tokens": 5000, "completion_tokens": 2,
               "ttft_s": 1, "elapsed_s": 2, "chunks": [{"elapsed_s": 1.9}],
               "saved_tokens": 4096, "cache_outcome": "hit", "decode_tps": 20}
        decode = dict(row, id="decode", kind="decode", saved_tokens=0, cache_outcome="miss")
        return {"rows": [row, decode], "tenant_checks": [row, row, dict(row, saved_tokens=0)],
                "cancelled": dict(row, token_ids=[12], finish="cancelled", cancel_requested=True),
                "recovered": dict(row, saved_tokens=0), "model": "fixture", "mtp": "off", "resolved_backend": "contiguous"}

    def test_identical_truncated_or_empty_results_are_not_success(self):
        for tokens, finish in [([], "length"), ([12], "cancelled")]:
            row = {"token_ids": tokens, "finish": finish, "completion_tokens": len(tokens)}
            self.assertTrue(mismatch(row, row))

    def test_same_text_different_token_ids_fails(self):
        row = {"token_ids": [12, 13], "finish": "length", "completion_tokens": 2}
        self.assertEqual(mismatch(row, dict(row, token_ids=[12, 14])), ["token_ids"])

    def test_prompt_changes_and_usage_inconsistency_are_visible(self):
        row = {"prompt_token_ids": [1, 2], "token_ids": [12], "finish": "stop", "completion_tokens": 1}
        other = dict(row, prompt_token_ids=[1, 3], completion_tokens=2)
        self.assertEqual(mismatch(row, other), ["completion_tokens", "prompt_token_ids", "token_count_inconsistent"])

    def test_valid_evidence_passes_but_zero_saving_does_not(self):
        baseline = self.fixture()
        self.assertTrue(compare(baseline, baseline, True)["passed"])
        candidate = copy.deepcopy(baseline)
        candidate["rows"][0]["saved_tokens"] = 0
        self.assertFalse(compare(baseline, candidate, True)["passed"])

    def test_tenant_leak_or_cancelled_publication_cannot_pass(self):
        for field in ("tenant_checks", "recovered"):
            baseline = self.fixture()
            candidate = copy.deepcopy(baseline)
            row = candidate[field][-1] if field == "tenant_checks" else candidate[field]
            row["saved_tokens"] = 4096
            self.assertFalse(compare(baseline, candidate, True)["passed"])

    def test_changed_mode_or_request_order_cannot_pass(self):
        baseline = self.fixture()
        candidate = copy.deepcopy(baseline)
        candidate["rows"].reverse()
        self.assertFalse(compare(baseline, candidate)["passed"])
        candidate = copy.deepcopy(baseline)
        candidate["mtp"] = "on"
        self.assertFalse(compare(baseline, candidate)["passed"])

    def test_latency_only_plan_has_no_invented_decode_rate(self):
        baseline = self.fixture()
        baseline["rows"] = baseline["rows"][:1]
        verdict = compare(baseline, baseline)
        self.assertTrue(verdict["passed"])
        self.assertIsNone(verdict["candidate_decode_tps"])

    def test_retained_bytes_above_budget_fail_even_with_exact_outputs(self):
        baseline = self.fixture()
        candidate = copy.deepcopy(baseline)
        candidate["hybrid_cache_requested_budget_bytes"] = 1024
        candidate["rows"][0]["metrics_after"] = {"hybrid_cache": {"retained_bytes": 1025}}
        self.assertFalse(compare(baseline, candidate)["passed"])

    def test_requested_mtp_requires_actual_driver_evidence(self):
        baseline = self.fixture()
        baseline["mtp"] = "on; normal Qwen inline assistant"
        verdict = compare(baseline, baseline)
        self.assertFalse(verdict["passed"])
        self.assertTrue(any(e.get("requested_mtp_not_active") for e in verdict["errors"]))

    def test_paged_cancel_reuses_finalized_blocks_but_still_requires_exact_recovery(self):
        baseline = self.fixture()
        baseline["resolved_backend"] = "paged"
        candidate = copy.deepcopy(baseline)
        candidate["recovered"]["saved_tokens"] = 4096
        self.assertTrue(compare(baseline, candidate)["passed"])
        candidate["recovered"]["token_ids"] = [99, 13]
        self.assertFalse(compare(baseline, candidate)["passed"])

    def test_requested_paged_cannot_silently_fall_back(self):
        report = self.fixture()
        report["requested_backend"] = "paged"
        self.assertFalse(compare(report, report)["passed"])

    def test_paged_complete_ssd_still_requires_natural_publication(self):
        report = self.ssd_fixture()
        report["resolved_backend"] = "paged"
        report["recovered"]["saved_tokens"] = 4096
        self.assertFalse(compare(report, report)["passed"])

    def batch_fixture(self):
        report = self.ssd_fixture()
        report["max_concurrent_requests"] = 2
        row = report["rows"][0]
        report["rows"] = [dict(row, id=f"repeat-b{i}", batch_id="repeat", batch_index=i,
                               outcome="completed") for i in range(2)]
        report["batches"] = [{"id": "repeat", "concurrency_requested": 2, "completed": 2,
                              "failed": 0, "peak_active_requests": 2,
                              "metrics_after_batch": {"ssd_cache": {"staged_bytes_in_use": 0},
                                                      "capacity": {"active_requests": 0}}}]
        return report

    def test_concurrent_staging_is_checked_after_whole_batch_drains(self):
        report = self.batch_fixture()
        report["rows"][0]["metrics_after"] = copy.deepcopy(report["rows"][0]["metrics_after"])
        report["rows"][0]["metrics_after"]["ssd_cache"]["staged_bytes_in_use"] = 100
        self.assertTrue(compare(report, report)["passed"])
        report["batches"][0]["metrics_after_batch"]["ssd_cache"]["staged_bytes_in_use"] = 100
        self.assertFalse(compare(report, report)["passed"])

    def test_failed_or_serialized_batch_cannot_pass(self):
        report = self.batch_fixture()
        report["batches"][0]["peak_active_requests"] = 1
        self.assertFalse(compare(report, report)["passed"])
        report["rows"][0] = {"id": "repeat-b0", "kind": "repeat", "outcome": "failed",
                             "batch_id": "repeat", "error": "capacity"}
        verdict = compare(report, report)
        self.assertFalse(verdict["passed"])
        self.assertTrue(any(item.get("batch_request_failed") for item in verdict["errors"]))

    def ssd_fixture(self):
        report = copy.deepcopy(self.fixture())
        report.update(cache_mode_requested="ssd", cache_requested=True)
        rows = report["rows"] + report["tenant_checks"] + [report["cancelled"], report["recovered"]]
        for row in rows:
            row.update(ssd_stage_disposition="staged", metrics_before={"ssd_cache": {"stage_read_bytes": 0}},
                       metrics_after={"cache_mode": "ssd_complete", "memory_cache_enabled": False,
                                      "resident_bank_budget_bytes": 0, "ssd_cache": {
                                          "staged_bytes_in_use": 0, "maximum_segment_bytes": 4194304,
                                          "stage_read_bytes": 5000000}})
        return report

    def test_ssd_requires_actual_store_without_idle_resident_state(self):
        original = self.ssd_fixture()
        self.assertTrue(compare(original, original)["passed"])
        for field, value in (("cache_mode", None), ("memory_cache_enabled", True), ("resident_bank_budget_bytes", 1)):
            candidate = copy.deepcopy(original)
            candidate["rows"][0]["metrics_after"][field] = value
            self.assertFalse(compare(original, candidate)["passed"])

    def test_ssd_hits_require_read_evidence_and_bounded_released_staging(self):
        original = self.ssd_fixture()
        for field, value in (("staged_bytes_in_use", 1), ("maximum_segment_bytes", 4194305), ("stage_read_bytes", 0)):
            candidate = copy.deepcopy(original)
            candidate["rows"][0]["metrics_after"]["ssd_cache"][field] = value
            self.assertFalse(compare(original, candidate)["passed"])

    def test_persistent_key_claim_rejects_actual_ephemeral_fallback(self):
        original = self.ssd_fixture()
        original["key_mode_requested"] = "persistent"
        rows = original["rows"] + original["tenant_checks"] + [original["cancelled"], original["recovered"]]
        for row in rows:
            row["metrics_after"]["key_mode"] = "persistent"
        self.assertTrue(compare(original, original)["passed"])
        candidate = copy.deepcopy(original)
        candidate["rows"][0]["metrics_after"]["key_mode"] = "ephemeral"
        self.assertFalse(compare(original, candidate)["passed"])


if __name__ == "__main__":
    unittest.main()
