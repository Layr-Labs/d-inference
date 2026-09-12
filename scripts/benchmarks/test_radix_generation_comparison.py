import copy
import contextlib
import io
import unittest
from unittest.mock import patch

import radix_generation_comparison
from radix_generation_comparison import comparison_records, policy_errors
from radix_engine_evidence import cancellation_errors, report_errors
from run_radix_engine import arguments, probe_command
import test_radix_engine_evidence as fixtures


class GenerationComparisonTests(unittest.TestCase):
    def test_repeated_pairs_hash_each_observation_once_without_aliasing_records(self):
        row = {"id": "same", "prompt_token_ids": [1, 2], "token_ids": [3, 4],
               "kind": "first", "scope": "a", "finish": "stop", "completion_tokens": 2}
        report = {"rows": [dict(row) for _ in range(4)]}
        sha256 = radix_generation_comparison.hashlib.sha256
        with patch.object(radix_generation_comparison.hashlib, "sha256", wraps=sha256) as hashes:
            records = comparison_records(report)
        self.assertEqual(6, len(records))
        self.assertEqual(8, hashes.call_count)  # token IDs and prompt IDs once per observation
        records[0]["left"]["id"] = "changed"
        self.assertEqual("same", records[1]["left"]["id"])
        self.assertTrue(all(row["tokens_equal"] for row in records))

    def fixture(self, policy="record"):
        r = fixtures.FinalEvidenceTests().primed_fixture()
        # The historical synthetic fixture aliases its two tenant-A rows.
        # Real report rows are independent observations with cold/warm counters.
        r["tenant_checks"] = [copy.deepcopy(row) for row in r["tenant_checks"]]
        for row in fixtures.FinalEvidenceTests.rows(r) + [r["cancel_donor"]]:
            row["completion_tokens"] = len(row["token_ids"])
        for i, row in enumerate(r["tenant_checks"]):
            row["scope"] = "tenant-A" if i < 2 else "tenant-B"
            row.update(cache_outcome="hit" if i == 1 else "miss", saved_tokens=4096 if i == 1 else 0,
                       matched_tokens=4096 if i == 1 else 0, ssd_stage_disposition="staged" if i == 1 else "miss_absent")
            row["metrics_before"]["ssd_cache"]["stage_read_bytes"] = 0
            row["metrics_after"]["ssd_cache"]["stage_read_bytes"] = 4096 if i == 1 else 0
        r["recovered"]["token_ids"] = [99, 13]
        r["recovered"]["completion_tokens"] = 2
        r["recovered"]["chunks"] = [{"elapsed_s": 1.9, "tokens": [99, 13]}]
        r["generation_comparison_policy"] = policy
        return self.seal(r)

    def seal(self, r):
        r["generated_token_comparisons"] = comparison_records(r)
        equal = bool(r["generated_token_comparisons"]) and all(c["tokens_equal"] for c in r["generated_token_comparisons"])
        r["generated_token_comparisons_pass"] = equal
        r["strict_generation_pass"] = r["generation_comparison_policy"] == "strict" and r["status"] == "completed" and equal
        return r

    def test_explicit_record_retains_failure_and_default_validator_rejects_it(self):
        r = self.fixture()
        self.assertEqual(policy_errors(r, "record"), [])
        self.assertIn("generation_comparison_policy_mismatch", policy_errors(r))
        self.assertEqual(cancellation_errors(r, "record"), [])
        self.assertEqual(report_errors(r, "record"), [])
        self.assertFalse(r["strict_generation_pass"])
        self.assertTrue(any(c["outcome"] == "FAIL" and c["first_difference_zero_based"] == 0 for c in r["generated_token_comparisons"]))
        strict = self.fixture("strict")
        self.assertIn("cancellation_donor_recovery_token_mismatch", cancellation_errors(strict))

    def test_record_cannot_hide_scope_prompt_cancel_restore_or_accounting_fault(self):
        for mutate in (
            lambda r: r["cancelled"].update(scope="wrong"),
            lambda r: r["cancelled"].update(prompt_token_ids=[999]),
            lambda r: r["cancelled"].update(cancel_requested=False),
            lambda r: r["cancelled"].update(saved_tokens=0),
            lambda r: r["cancelled"]["metrics_after"]["ssd_cache"].update(stage_read_bytes=0),
            lambda r: r["recovered"].update(token_ids=[]),
        ):
            r = self.fixture(); mutate(r); self.seal(r)
            self.assertTrue(cancellation_errors(r, "record"))
        r = self.fixture(); r["recovered"]["chunks"][0]["tokens"] = [55]
        self.assertTrue(any("chunk_token_ids_inconsistent" in e for e in report_errors(r, "record")))
        r = self.fixture(); r["recovered"]["metrics_after"]["capacity"]["active_requests"] = 1
        self.assertTrue(report_errors(r, "record"))
        r = self.fixture(); r["recovered"]["completion_tokens"] += 1; self.seal(r)
        self.assertTrue(any("generated_token_accounting_inconsistent" in e for e in report_errors(r, "record")))
        for key in ("rows", "tenant_checks", "cancel_donor", "cancelled", "recovered"):
            for field, value in (("completion_tokens", -1), ("token_ids", [-1])):
                r = self.fixture()
                row = r[key][0] if key in ("rows", "tenant_checks") else r[key]
                row[field] = value
                self.seal(r)
                self.assertTrue(any("generated_token_accounting_inconsistent" in e for e in report_errors(r, "record")), key)
        r = self.fixture(); r["tenant_checks"][2]["saved_tokens"] = 4096
        self.assertTrue(any("cross_tenant_cache_hit" in e for e in report_errors(r, "record")))

    def test_auth_is_checked_even_with_strict_token_failure(self):
        r = self.fixture("strict")
        r["cancelled"]["saved_tokens"] = 0
        errors = cancellation_errors(r)
        self.assertIn("cancellation_donor_recovery_token_mismatch", errors)
        self.assertIn("cancel_after_restore_not_exercised", errors)

    def test_records_reject_tampering_missing_and_invented_policy(self):
        for mutate in (lambda r: r.pop("generated_token_comparisons"),
                       lambda r: r.update(strict_generation_pass=True),
                       lambda r: r["generated_token_comparisons"][0].update(outcome="PASS", tokens_equal=True, first_difference_zero_based=900),
                       lambda r: r.update(generation_comparison_policy="ignore")):
            r = self.fixture(); mutate(r)
            self.assertTrue(policy_errors(r, "record"))
        self.assertTrue(report_errors({"schema": 1}, "record"))
        self.assertTrue(policy_errors(self.fixture(), "anything"))

    def test_cancel_prefix_longer_than_donor_is_a_difference(self):
        r = self.fixture(); r["cancelled"]["token_ids"] = r["cancel_donor"]["token_ids"] + [99]
        c = next(c for c in comparison_records(r) if c["left"]["path"] == "cancel_donor" and c["right"]["path"] == "cancelled")
        self.assertFalse(c["tokens_equal"])
        self.assertEqual(c["first_difference_zero_based"], len(r["cancel_donor"]["token_ids"]))

    def test_wrapper_default_command_unchanged_and_explicit_policy_forwarded(self):
        base = ["--binary", "/binary", "--model-directory", "/model", "--input", "/input", "--output", "/output"]
        original = probe_command(arguments(base), "/report")
        self.assertNotIn("--generation-comparison-policy", original)
        for policy in ("strict", "record"):
            command = probe_command(arguments(base + ["--generation-comparison-policy", policy]), "/report")
            self.assertEqual(command, original + ["--generation-comparison-policy", policy])
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            arguments(base + ["--generation-comparison-policy", "ignore"])
