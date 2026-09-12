import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest

from compare_radix_engine import compare
from radix_engine_evidence import memory_errors, production_grant_errors, cancellation_errors
from run_radix_engine import arguments, mark_aborted_report, pin_prompt_date, probe_command, sha256
import test_compare_radix_engine as legacy_evidence
import test_run_radix_engine as legacy_invocation


class FinalEvidenceTests(unittest.TestCase):
    def fixture(self):
        report = legacy_evidence.TokenEvidenceTests().ssd_fixture()
        memory = dict(cap_bytes=1000, activation_reserve_bytes=100, active_bytes=200, cache_bytes=20,
                      charged_bytes=300, materialized_bytes=150, unmaterialized_bytes=150,
                      remaining_bytes=530, commitment_debt_bytes=0, owner_count=1,
                      closing_owner_count=0, policy_epoch=1, generation=1, sample_seq=1,
                      system_available_bytes=None)
        report.update(schema=2, status="completed", verified_model_hash="a" * 64,
                      expected_model_sha256="a" * 64, input_sha256="b" * 64,
                      runtime_identity=dict(normalization="n", renderer="r", tokenizer="t",
                                            binary_sha256="c" * 64, metallib_sha256="d" * 64))
        for row in self.rows(report):
            row.update(outcome="cancelled" if row.get("cancel_requested") else "completed",
                       prompt_render_date="2026-09-05", chunks=[{"elapsed_s": 1.9, "tokens": row["token_ids"]}],
                       first_delta_token_count=len(row["token_ids"]), decode_tokens_after_first_delta=0, decode_tps=0)
            for key in ("metrics_before", "metrics_after"):
                metrics = row[key]
                metrics["process_memory"] = dict(memory)
                metrics["capacity"] = dict(active_requests=0, waiting_requests=0,
                                           kv_in_use_bytes=0, kv_reserved_bytes=0)
                metrics["ssd_cache"].update(write_host_bytes_in_use=0, peak_write_host_bytes=20971520,
                                             write_host_capacity_refusals=0)
        report["warmup"] = dict(report["rows"][0])
        report["metrics_loaded"] = copy.deepcopy(report["rows"][0]["metrics_before"])
        report["metrics_after_shutdown"] = copy.deepcopy(report["rows"][0]["metrics_after"])
        report["metrics_after_shutdown"]["process_memory"].update(
            owner_count=0, closing_owner_count=0, charged_bytes=0, materialized_bytes=0,
            unmaterialized_bytes=0, remaining_bytes=680)
        return report

    @staticmethod
    def rows(report):
        return report["rows"] + report["tenant_checks"] + [report["cancelled"], report["recovered"]]

    @staticmethod
    def cold_control(report):
        cold = copy.deepcopy(report)
        cold["cache_requested"] = False
        rows = FinalEvidenceTests.rows(cold)
        if "cancel_donor" in cold:
            rows.append(cold["cancel_donor"])
        for row in rows:
            row.update(saved_tokens=0, matched_tokens=0, cache_outcome="disabled",
                       ssd_stage_disposition="not_attempted")
        return cold

    def primed_fixture(self):
        report = self.fixture()
        report.update(cancellation_probe_version=2, cancellation_probe_outcome="observed", resolved_backend="paged")
        report["cancel_donor"] = copy.deepcopy(report["recovered"])
        for key in ("cancel_donor", "cancelled", "recovered"):
            report[key]["scope"] = "exact-cancel-scope"
        report["cancelled"]["matched_tokens"] = 4096
        report["recovered"]["saved_tokens"] = 4096
        for row in self.rows(report) + [report["cancel_donor"]]:
            for moment in ("metrics_before", "metrics_after"):
                row[moment]["paged_storage"] = dict(
                    allocator_padding_bytes=0, last_allocation_allowance_bytes=0,
                    committed_bytes=0, segment_count=0, live_page_bytes=0,
                    reserved_page_bytes=0, address_pages=1050)
        for moment in ("metrics_loaded", "metrics_after_shutdown"):
            report[moment]["paged_storage"] = copy.deepcopy(report["rows"][0]["metrics_after"]["paged_storage"])
        return report

    def test_primed_cancel_requires_same_scope_completed_donor_and_exact_recovery(self):
        original = self.primed_fixture()
        self.assertEqual(cancellation_errors(original), [])
        self.assertTrue(compare(self.cold_control(original), original)["passed"])
        for mutate in (lambda r: r.pop("cancel_donor"),
                       lambda r: r["cancel_donor"].update(outcome="failed"),
                       lambda r: r["cancelled"].update(scope="fresh-cold-scope"),
                       lambda r: r["cancelled"].update(prompt_token_ids=[99]),
                       lambda r: r["cancelled"].update(finish="length"),
                       lambda r: r["recovered"].update(token_ids=[99, 13])):
            changed = copy.deepcopy(original)
            mutate(changed)
            self.assertTrue(cancellation_errors(changed))
            self.assertFalse(compare(self.cold_control(original), changed)["passed"])

    def test_paged_ssd_cancellation_requires_fresh_read_match_and_real_saved_work(self):
        original = self.primed_fixture()
        for field, value in (("saved_tokens", 0), ("matched_tokens", 0),
                             ("cache_outcome", "miss"), ("ssd_stage_disposition", "bypassed")):
            changed = copy.deepcopy(original)
            changed["cancelled"][field] = value
            self.assertIn("cancel_after_restore_not_exercised", cancellation_errors(changed))
        changed = copy.deepcopy(original)
        changed["cancelled"]["metrics_after"]["ssd_cache"]["stage_read_bytes"] = 0
        self.assertIn("cancel_after_restore_not_exercised", cancellation_errors(changed))
        cold = copy.deepcopy(original)
        cold["cache_requested"] = False
        cold["cancelled"].update(saved_tokens=0, matched_tokens=0, cache_outcome="disabled", ssd_stage_disposition="bypassed")
        self.assertEqual(cancellation_errors(cold), [])
        cold["cancelled"]["saved_tokens"] = 1
        self.assertIn("cache_disabled_cancel_restored_prefix", cancellation_errors(cold))

    def test_old_and_primed_cancellation_are_distinct_comparison_protocols(self):
        old = self.fixture()
        new = self.primed_fixture()
        new["resolved_backend"] = "contiguous"
        self.assertFalse(compare(self.cold_control(old), new)["passed"])
        for malformed in (True, "2", None, 3):
            changed = copy.deepcopy(new)
            changed["cancellation_probe_version"] = malformed
            self.assertIn("invalid_cancellation_probe_version", cancellation_errors(changed))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "report.json"
            path.write_text(json.dumps(dict(status="running", cancel_donor=dict(outcome="running"))))
            mark_aborted_report(path, "owned process interrupted")
            self.assertEqual(json.loads(path.read_text())["cancel_donor"]["outcome"], "aborted")

    def test_production_grant_requires_loaded_weights_live_gate_and_matching_authority(self):
        gib = 1 << 30
        hard = int(128 * gib * 0.90)
        grant = dict(physical_bytes=128 * gib, cap_fraction=0.90, hard_cap_bytes=hard,
                     effective_cap_bytes=hard, operator_reserve_bytes=4 * gib,
                     activation_reserve_bytes=11 * gib // 2, target_weight_bytes=20 * gib,
                     assistant_weight_bytes=gib, resident_weight_bytes=21 * gib,
                     ram_prefix_allowance_bytes=0, slot_count=1,
                     fleet_budget_bytes=hard - 21 * gib - 11 * gib // 2,
                     grant_bytes=hard - 21 * gib - 11 * gib // 2)
        report = dict(kv_grant_mode="production_single_slot", kv_budget_bytes=grant["grant_bytes"],
                      production_grant=grant, metrics_loaded=dict(production_grant=copy.deepcopy(grant),
                          engine_kv_capacity_bytes=grant["grant_bytes"], post_build_headroom_bytes=2 * gib,
                          process_memory=dict(cap_bytes=hard, activation_reserve_bytes=11 * gib // 2)))
        self.assertEqual(production_grant_errors(report), [])
        mutations = [lambda r: r["production_grant"].update(assistant_weight_bytes=0),
                     lambda r: r["production_grant"].update(slot_count=2),
                     lambda r: r.update(kv_budget_bytes=16 * gib),
                     lambda r: r["metrics_loaded"].update(post_build_headroom_bytes=gib - 1),
                     lambda r: r["metrics_loaded"]["process_memory"].update(cap_bytes=128 * gib)]
        for mutate in mutations:
            changed = copy.deepcopy(report)
            mutate(changed)
            self.assertTrue(production_grant_errors(changed))
        # Explicit envelope reports remain supported without production claims.
        self.assertEqual(production_grant_errors({"kv_grant_mode": "explicit"}), [])

    def test_final_evidence_requires_coherent_memory_and_all_host_fields(self):
        original = self.fixture()
        self.assertTrue(compare(self.cold_control(original), original)["passed"])
        for field, value in (("charged_bytes", 100), ("remaining_bytes", 999),
                             ("closing_owner_count", 2), ("unmaterialized_bytes", 0)):
            candidate = copy.deepcopy(original)
            candidate["rows"][0]["metrics_after"]["process_memory"][field] = value
            self.assertFalse(compare(self.cold_control(original), candidate)["passed"])
        for field in ("write_host_bytes_in_use", "peak_write_host_bytes", "write_host_capacity_refusals"):
            candidate = copy.deepcopy(original)
            del candidate["rows"][0]["metrics_after"]["ssd_cache"][field]
            self.assertFalse(compare(self.cold_control(original), candidate)["passed"])
        candidate = copy.deepcopy(original)
        candidate["rows"][0]["metrics_after"]["ssd_cache"]["write_host_bytes_in_use"] = 1
        self.assertFalse(compare(self.cold_control(original), candidate)["passed"])

    def test_unknown_os_headroom_and_policy_debt_keep_exact_accounting(self):
        memory = self.fixture()["metrics_loaded"]["process_memory"]
        self.assertEqual(memory_errors(memory), [])
        memory.update(system_available_bytes=120, remaining_bytes=0, commitment_debt_bytes=130)
        self.assertEqual(memory_errors(memory), [])
        memory["commitment_debt_bytes"] = 0
        self.assertEqual(memory_errors(memory), ["inconsistent_process_headroom"])

    def test_partial_and_not_run_cells_cannot_be_promoted(self):
        good = self.fixture()
        for status in ("loading", "running", "failed", "aborted"):
            partial = {"schema": 2, "status": status, "rows": [{"id": "pending", "outcome": "not_run"}]}
            verdict = compare(self.cold_control(good), partial)
            self.assertFalse(verdict["passed"])
            self.assertFalse(verdict["generated_token_ids_compared"])
        partial = copy.deepcopy(good)
        partial["rows"][0] = {"id": "repeat", "outcome": "not_run"}
        self.assertFalse(compare(self.cold_control(good), partial)["passed"])

    def test_identity_date_duplicates_and_chunk_tampering_fail(self):
        good = self.fixture()
        changes = [lambda r: r.update(verified_model_hash="f" * 64),
                   lambda r: r.update(input_sha256="f" * 64),
                   lambda r: r["rows"][0].update(prompt_render_date="2026-09-06"),
                   lambda r: r["rows"][1].update(id=r["rows"][0]["id"]),
                   lambda r: r["rows"][0]["chunks"][0].update(tokens=[99])]
        for mutate in changes:
            changed = copy.deepcopy(good)
            mutate(changed)
            self.assertFalse(compare(self.cold_control(good), changed)["passed"])

    def test_paged_metrics_and_contiguous_no_fallback_are_explicit(self):
        good = self.fixture()
        good["requested_backend"] = "contiguous"
        changed = copy.deepcopy(good)
        changed["backend_fallback"] = "unexpected"
        self.assertFalse(compare(self.cold_control(good), changed)["passed"])
        good.update(requested_backend="paged", resolved_backend="paged")
        self.assertFalse(compare(self.cold_control(good), good)["passed"])

    def test_active_mtp_with_no_verification_is_not_final_evidence(self):
        good = self.fixture()
        good["mtp"] = "on; production configured assistant"
        good["metrics_loaded"]["assistant_identity"] = {"source": "local", "config_sha256": "e" * 64}
        for row in self.rows(good):
            for key in ("metrics_before", "metrics_after"):
                row[key]["mtp"] = {"active": True, "rounds": 0}
        self.assertFalse(compare(self.cold_control(good), good)["passed"])
        for row in self.rows(good):
            row["metrics_after"]["mtp"]["rounds"] = 1
        self.assertTrue(compare(self.cold_control(good), good)["passed"])


class FinalInvocationTests(unittest.TestCase):
    def test_exact_options_are_argv_not_shell_text(self):
        args = arguments(legacy_invocation.EngineInvocationTests.base + ["--cache-mode", "ssd",
            "--assistant-directory", "/assistant with spaces", "--expected-model-sha256", "a" * 64,
            "--prompt-date", "2026-09-05", "--trial", "3"])
        self.assertEqual(probe_command(args, "/result.json")[-4:],
            ["--assistant-directory", "/assistant with spaces", "--expected-model-sha256", "a" * 64])
        self.assertEqual(args.trial, 3)

    def test_invalid_identity_date_and_resident_override_refuse_early(self):
        for extra in (["--prompt-date", "2026-02-29"], ["--prompt-date", "20260905"],
                      ["--trial", "0"], ["--expected-model-sha256", "A" * 64],
                      ["--cache-mode", "resident", "--assistant-directory", "/a"]):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                arguments(legacy_invocation.EngineInvocationTests.base + extra)

    def test_pin_preserves_tools_and_explicit_request_date(self):
        body = {"model": "opaque", "messages": [{"role": "assistant", "content": None,
                "tool_calls": [{"id": "c", "function": {"name": "lookup", "arguments": "{}"}}]}],
                "tools": [{"type": "function", "function": {"name": "lookup"}}],
                "chat_template_kwargs": {"enable_thinking": False}}
        rows = [{"case": {"id": "one"}, "request": body},
                {"case": {"id": "two"}, "request": dict(body, _darkbloom_prompt_date="2024-02-29")}]
        with tempfile.TemporaryDirectory() as root:
            source, target = Path(root) / "source.json", Path(root) / "input.json"
            source.write_text(json.dumps({"rows": rows}))
            original_hash = sha256(source)
            pin_prompt_date(source, target, "2026-09-05")
            actual = json.loads(target.read_text())["rows"]
            self.assertEqual(actual[0]["request"], dict(body, _darkbloom_prompt_date="2026-09-05"))
            self.assertEqual(actual[1]["request"], rows[1]["request"])
            self.assertEqual(sha256(source), original_hash)
            rows[1]["case"]["id"] = "one"
            source.write_text(json.dumps({"rows": rows}))
            with self.assertRaises(ValueError):
                pin_prompt_date(source, target, "2026-09-05")

    def test_abort_preserves_completed_failed_and_unrun_cells(self):
        with tempfile.TemporaryDirectory() as root:
            target = Path(root) / "report.json"
            target.write_text(json.dumps({"status": "running", "rows": [
                {"outcome": "completed", "token_ids": [1, 2]}, {"outcome": "failed", "error": "capacity"},
                {"outcome": "running"}, {"outcome": "not_run"}]}))
            mark_aborted_report(target, "bounded timeout")
            actual = json.loads(target.read_text())
            self.assertEqual(actual["status"], "aborted")
            self.assertEqual([row["outcome"] for row in actual["rows"]],
                             ["completed", "failed", "aborted", "not_run"])
            self.assertEqual(actual["rows"][0]["token_ids"], [1, 2])
            mark_aborted_report(target, "later")
            self.assertEqual(json.loads(target.read_text()), actual)

class ComparisonAxisTests(unittest.TestCase):
    def pair(self):
        baseline = FinalEvidenceTests().fixture()
        baseline.update(requested_backend="contiguous", resolved_backend="contiguous", key_mode_requested="ephemeral")
        candidate = copy.deepcopy(baseline)
        candidate.update(requested_backend="paged", resolved_backend="paged")
        for row in FinalEvidenceTests.rows(baseline) + FinalEvidenceTests.rows(candidate):
            for key in ("metrics_before", "metrics_after"):
                row[key]["key_mode"] = "ephemeral"
        for row in FinalEvidenceTests.rows(candidate):
            for key in ("metrics_before", "metrics_after"):
                row[key]["paged_storage"] = dict(
                    allocator_padding_bytes=1024, last_allocation_allowance_bytes=4096,
                    committed_bytes=0, segment_count=0, live_page_bytes=0, reserved_page_bytes=0)
        for moment in ("metrics_loaded", "metrics_after_shutdown"):
            candidate[moment]["paged_storage"] = copy.deepcopy(candidate["rows"][0]["metrics_after"]["paged_storage"])
        return baseline, candidate

    def test_backend_axis_is_explicit_and_cache_axis_still_requires_one_backend(self):
        baseline, candidate = self.pair()
        self.assertFalse(compare(baseline, candidate)["passed"])
        verdict = compare(baseline, candidate, axis="backend")
        self.assertTrue(verdict["passed"], verdict["errors"])
        self.assertEqual(verdict["comparison_axis"], "backend")
        self.assertFalse(compare(candidate, baseline, axis="backend")["passed"])
        self.assertFalse(compare(candidate, candidate, axis="backend")["passed"])

    def test_backend_axis_rejects_cache_key_identity_grant_or_concurrency_change(self):
        baseline, candidate = self.pair()
        for key, value in (("cache_requested", False), ("cache_mode_requested", "resident"),
                           ("key_mode_requested", "persistent"), ("verified_model_hash", "f" * 64),
                           ("input_sha256", "e" * 64), ("kv_budget_bytes", 42),
                           ("max_concurrent_requests", 2)):
            changed = copy.deepcopy(candidate)
            changed[key] = value
            self.assertFalse(compare(baseline, changed, axis="backend")["passed"], key)

    def test_fast_stop_is_not_cancellation_evidence(self):
        baseline, candidate = self.pair()
        candidate["cancelled"].update(finish="stop", cancel_requested=False, outcome="completed")
        self.assertFalse(compare(baseline, candidate, axis="backend")["passed"])


class DecodeTimingTests(unittest.TestCase):
    def test_mtp_first_chunk_does_not_receive_untimed_decode_credit(self):
        from radix_engine_evidence import decode_timing_errors
        row = {"chunks": [{"elapsed_s": 2.0, "tokens": [11, 12, 13]},
                          {"elapsed_s": 2.5, "tokens": [14, 15]},
                          {"elapsed_s": 3.0, "tokens": [16]}],
               "first_delta_token_count": 3, "decode_tokens_after_first_delta": 3, "decode_tps": 3.0}
        self.assertEqual(decode_timing_errors(row), [])
        # The old (all tokens - 1) numerator incorrectly reports 5 tokens/s.
        self.assertEqual(decode_timing_errors(dict(row, decode_tps=5.0)),
                         ["decode_timing_inconsistent_with_chunks"])
        row.update(chunks=row["chunks"][:1], decode_tokens_after_first_delta=0, decode_tps=0)
        self.assertEqual(decode_timing_errors(row), [])
