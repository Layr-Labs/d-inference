"""Final-cell regressions use synthetic reports, never substitute for model runs."""

import copy
import unittest

from compare_radix_engine import compare
from radix_engine_evidence import report_errors
import test_radix_engine_evidence as fixtures


class AcceptanceTests(unittest.TestCase):
    def pair(self, concurrency=1):
        candidate = fixtures.FinalEvidenceTests().primed_fixture()
        # Separate fixture objects just as JSON decoding separates observations.
        for key in ("rows", "tenant_checks"):
            candidate[key] = [copy.deepcopy(row) for row in candidate[key]]
        candidate.update(requested_backend="paged", key_mode_requested="ephemeral")
        for row in fixtures.FinalEvidenceTests.rows(candidate) + [candidate["cancel_donor"]]:
            for moment in ("metrics_before", "metrics_after"):
                row[moment]["key_mode"] = "ephemeral"
        if concurrency > 1:
            first = candidate["rows"][0]
            candidate["rows"] = [dict(copy.deepcopy(first), id=f"repeat-b{i}",
                                     batch_id="repeat", batch_index=i) for i in range(concurrency)]
            candidate["max_concurrent_requests"] = concurrency
            candidate["batches"] = [dict(id="repeat", concurrency_requested=concurrency,
                completed=concurrency, failed=0, peak_active_requests=concurrency,
                metrics_after_batch=copy.deepcopy(first["metrics_after"]), capacity_samples=[])]
        return fixtures.FinalEvidenceTests.cold_control(candidate), candidate

    def test_cache_axis_requires_disabled_to_enabled_with_same_store_and_key(self):
        cold, warm = self.pair()
        self.assertTrue(compare(cold, warm, True)["passed"])
        for left, right in ((warm, warm), (cold, cold), (warm, cold)):
            with self.subTest(left=left["cache_requested"], right=right["cache_requested"]):
                self.assertFalse(compare(left, right)["passed"])
        for key, value in (("cache_mode_requested", "resident"), ("key_mode_requested", "persistent")):
            changed = copy.deepcopy(cold)
            changed[key] = value
            with self.subTest(key=key):
                self.assertFalse(compare(changed, warm)["passed"])

    def test_disabled_oracle_cannot_reuse_a_prefix_outside_cancelled_probe(self):
        cold, warm = self.pair()
        for key in ("rows", "tenant_checks", "cancel_donor", "recovered"):
            changed = copy.deepcopy(cold)
            row = changed[key][0] if isinstance(changed[key], list) else changed[key]
            row.update(saved_tokens=1024, cache_outcome="hit", ssd_stage_disposition="staged")
            with self.subTest(key=key):
                self.assertFalse(compare(changed, warm)["passed"])

    def test_serial_idle_requires_retired_requests_pages_and_staging_in_both_arms(self):
        for arm in (0, 1):
            for owner, field in (("capacity", "active_requests"), ("capacity", "waiting_requests"),
                                 ("capacity", "kv_in_use_bytes"), ("capacity", "kv_reserved_bytes"),
                                 ("paged_storage", "live_page_bytes"),
                                 ("paged_storage", "reserved_page_bytes"),
                                 ("ssd_cache", "staged_bytes_in_use")):
                pair = self.pair()
                pair[arm]["rows"][0]["metrics_after"][owner][field] = 1
                with self.subTest(arm=arm, owner=owner, field=field):
                    self.assertFalse(compare(*pair)["passed"])

    def test_shutdown_rejects_coherent_lingering_owners_and_native_backing(self):
        for arm in (0, 1):
            pair = self.pair()
            metrics = pair[arm]["metrics_after_shutdown"]
            metrics["process_memory"].update(owner_count=1, closing_owner_count=1,
                charged_bytes=300, materialized_bytes=150, unmaterialized_bytes=150,
                remaining_bytes=530)
            with self.subTest(arm=arm, ownership=True):
                self.assertFalse(compare(*pair)["passed"])
            for owner, field in (("paged_storage", "segment_count"),
                                 ("paged_storage", "committed_bytes"),
                                 ("ssd_cache", "staged_bytes_in_use")):
                pair = self.pair()
                pair[arm]["metrics_after_shutdown"][owner][field] = 1
                with self.subTest(arm=arm, owner=owner, field=field):
                    self.assertFalse(compare(*pair)["passed"])

    def test_free_backing_at_idle_and_address_space_and_weights_after_shutdown_are_valid(self):
        cold, warm = self.pair()
        for report in (cold, warm):
            idle = report["rows"][0]["metrics_after"]
            idle["paged_storage"].update(committed_bytes=128, segment_count=1)
            idle["capacity"]["kv_reserved_bytes"] = 128
            shutdown = report["metrics_after_shutdown"]
            self.assertGreater(shutdown["process_memory"]["active_bytes"], 0)
            self.assertGreater(shutdown["process_memory"]["cache_bytes"], 0)
            self.assertGreater(shutdown["paged_storage"]["address_pages"], 0)
        self.assertTrue(compare(cold, warm)["passed"])

    def test_concurrent_rows_can_overlap_but_both_batch_oracles_must_drain(self):
        cold, warm = self.pair(concurrency=4)
        for report in (cold, warm):
            during = report["rows"][0]["metrics_after"]
            during["capacity"].update(active_requests=3, kv_in_use_bytes=128, kv_reserved_bytes=256)
            during["paged_storage"].update(live_page_bytes=128, reserved_page_bytes=256)
            during["ssd_cache"].update(staged_bytes_in_use=128, write_host_bytes_in_use=128)
            # B4 is a requested batch width; sampled overlap proves concurrency,
            # without fabricating a precise peak of four admitted sequences.
            report["batches"][0]["peak_active_requests"] = 2
        self.assertTrue(compare(cold, warm)["passed"])
        for arm in (0, 1):
            for change in ("serialized", "missing_batch", "undrained"):
                pair = copy.deepcopy((cold, warm))
                batch = pair[arm]["batches"][0]
                if change == "serialized":
                    batch["peak_active_requests"] = 1
                elif change == "missing_batch":
                    pair[arm]["batches"] = []
                else:
                    batch["metrics_after_batch"]["capacity"]["kv_in_use_bytes"] = 1
                with self.subTest(arm=arm, change=change):
                    self.assertFalse(compare(*pair)["passed"])

    def test_retirement_fields_cannot_be_omitted(self):
        cold, warm = self.pair()
        for owner, field in (("capacity", "kv_reserved_bytes"),
                             ("paged_storage", "live_page_bytes"),
                             ("paged_storage", "committed_bytes")):
            changed = copy.deepcopy(warm)
            del changed["rows"][0]["metrics_after"][owner][field]
            with self.subTest(owner=owner, field=field):
                self.assertTrue(report_errors(changed))

    def test_substripe_repeat_may_be_cold_without_claiming_a_restore(self):
        cold, warm = self.pair()
        for report in (cold, warm):
            row = report["rows"][0]
            row.update(prompt_token_ids=[1] * 1607, prompt_tokens=1607,
                       saved_tokens=0, matched_tokens=0, cache_outcome="miss_absent",
                       ssd_stage_disposition="miss_absent")
        # Tenant/cancellation controls retain longer primed inputs and prove
        # real restore. The 1607-token row itself has no 2048-token checkpoint.
        self.assertTrue(compare(cold, warm, True)["passed"])


if __name__ == "__main__":
    unittest.main()
