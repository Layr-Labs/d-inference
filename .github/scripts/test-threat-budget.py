#!/usr/bin/env python3
"""Offline HTTP integration tests for budgets, reuse, escalation and delivery."""
import base64
import copy
from contextlib import redirect_stdout, redirect_stderr
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import runpy
import threading
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

from threat_review.budget_runner import run
from threat_review.budget_scan import Scanner, failure
from threat_review.bedrock import BedrockCalls
from threat_review.client import APIError, GitHub, ReviewUnavailable, request_json
from threat_review.context import ThreatContext, SONNET, OPUS, SOL
from threat_review.paid import PaidCalls, microdollars
from threat_review.merge_policy import clean
from threat_review.preflight import check as preflight
from threat_review.report import COMMENT_LIMIT, plain
from threat_review.source import complete_files
from threat_review.state import State, BudgetStopped, fresh, WRITE_ATTEMPTS

spec = importlib.util.spec_from_file_location("fixtures", Path(__file__).with_name("test-threat-model-review.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class LocalService:
    def __init__(self):
        self.files, self.lock, self.calls = {}, threading.Lock(), []
        self.reply = self.completion
        self.fail_write = False
        self.conflicts = 0
        self.verified = True
        self.branch_version = 0
        self.write_barrier = None
        self.barrier_writers = 0
        self.branch_conflicts = 0
        self.conflict_path = None
        self.write_attempts = []
        service = self
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def send(self, status, value):
                self.send_response(status)
                self.end_headers()
                self.wfile.write(json.dumps(value).encode())

            def do_GET(self):
                if "/commits/" in self.path:
                    return self.send(200, {"commit": {"verification": {"verified": service.verified}}})
                path = urlsplit(self.path).path.split("/contents/", 1)[-1]
                with service.lock:
                    value = copy.deepcopy(service.files.get(path))
                return self.send(200 if value else 404, value or {})

            def do_PUT(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                path = self.path.split("/contents/", 1)[-1]
                self.assert_branch(body)
                with service.lock:
                    branch_version = service.branch_version
                    barrier = service.write_barrier if service.barrier_writers else None
                    if barrier:
                        service.barrier_writers -= 1
                if barrier:
                    barrier.wait(timeout=5)
                with service.lock:
                    service.write_attempts.append(path)
                    old = service.files.get(path)
                    if service.fail_write:
                        return self.send(403, {"message": "secret provider payload"})
                    if branch_version != service.branch_version or (service.branch_conflicts and
                            (service.conflict_path is None or path == service.conflict_path)):
                        service.branch_conflicts = max(0, service.branch_conflicts - 1)
                        service.conflicts += 1
                        return self.send(409, {})
                    if (old and body.get("sha") != old["sha"]) or (not old and "sha" in body):
                        service.conflicts += 1
                        return self.send(409, {})
                    raw = base64.b64decode(body["content"])
                    sha = hashlib.sha1(raw).hexdigest()
                    service.files[path] = {"sha": sha, "encoding": "base64", "size": len(raw), "content": body["content"]}
                    service.branch_version += 1
                return self.send(200, {"commit": {"sha": sha}})

            def assert_branch(self, body):
                if body["branch"] != "codex/threat-review-state":
                    raise AssertionError("attempt to write outside state branch")

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                service.calls.append(copy.deepcopy(body))
                result = service.reply(body)
                if isinstance(result, int):
                    return self.send(result, {"secret": "never print this"})
                return self.send(200, result)
        class ConcurrentHTTPServer(ThreadingHTTPServer):
            # Admit the whole contention fixture before any handler waits at
            # the barrier; the default five-connection backlog can starve it.
            request_queue_size = 32

        self.server = ConcurrentHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.url = f"http://127.0.0.1:{self.server.server_port}"
        self.github = GitHub("example/repo", 12, "synthetic", self.transport)
        self.state = State(self.github)
        self.state.write("ledger.json", fresh())

    def transport(self, url, token, payload=None, method=None):
        route = urlsplit(url).path
        if "/contents/" not in route and "/commits/" not in route:
            route = "/model"
        return request_json(self.url + route, "synthetic", payload, method)

    def completion(self, body, findings=(), cost=0.01, uncertain=False):
        sent = json.loads(body["messages"][1]["content"])
        result = {"findings": list(findings), "covered_units": [u["id"] for u in sent["units"]],
                  "analysis": "Trace the changed behavior and its cross-file implications.",
                  "needs_deeper_review": uncertain}
        return {"usage": {"cost": cost, "prompt_tokens_details": {"cached_tokens": 12}},
                "choices": [{"finish_reason": "stop", "message": {"content": json.dumps(result)}}]}

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.service = LocalService()
        self.addCleanup(self.service.close)
        self.state = self.service.state

    def test_different_report_files_recover_shared_branch_conflict(self):
        self.service.write_barrier = threading.Barrier(2)
        self.service.barrier_writers = 2
        with ThreadPoolExecutor(2) as pool:
            urls = list(pool.map(lambda n: self.state.checkpoint(f"{n}-1", {"progress": n}), (1, 2)))
        self.assertEqual(self.service.conflicts, 1)
        self.assertEqual(len(urls), 2)
        for n in (1, 2):
            self.assertEqual(self.state.read(f"reports/{n}-1.json")[0], {"progress": n})

    def test_cache_creation_retries_branch_conflict_without_overwriting_existing_cache(self):
        key = "a" * 64
        self.service.branch_conflicts = 1
        self.state.save_cache(key, {"analysis": "original"})
        self.assertEqual(self.service.conflicts, 1)
        self.state.save_cache(key, {"analysis": "replacement"})
        self.assertEqual(self.state.cached(key), {"analysis": "original"})

    def test_report_conflict_exhaustion_has_bounded_attempts_and_safe_diagnostics(self):
        self.service.branch_conflicts = 100
        with patch("threat_review.state.conflict_backoff"), self.assertRaises(APIError) as caught:
            self.state.checkpoint("1-1", {"private": "source"})
        self.assertEqual(self.service.write_attempts.count("reports/1-1.json"), WRITE_ATTEMPTS)
        self.assertEqual(caught.exception.diagnostic, {
            "code": "STATE_WRITE_FAILED", "service": "github", "operation": "report", "http_status": 409,
            "write_attempts": WRITE_ATTEMPTS, "write_limit": WRITE_ATTEMPTS})

    def test_report_recovers_a_conflict_burst_longer_than_the_old_window(self):
        self.service.branch_conflicts = 9
        with patch("threat_review.state.conflict_backoff"):
            self.state.checkpoint("1-1", {"coverage": "preserved"})
        self.assertEqual(self.service.conflicts, 9)
        self.assertEqual(self.state.read("reports/1-1.json")[0], {"coverage": "preserved"})
        self.assertFalse(self.service.calls)

    def test_twelve_simultaneous_report_writers_preserve_each_others_data(self):
        self.service.write_barrier = threading.Barrier(12)
        self.service.barrier_writers = 12
        with ThreadPoolExecutor(12) as pool:
            reports = list(pool.map(lambda n: self.state.checkpoint(f"{n}-1", {"writer": n}), range(1, 13)))
        self.assertEqual(len(reports), 12)
        self.assertGreaterEqual(self.service.conflicts, 11)
        for n in range(1, 13):
            self.assertEqual(self.state.read(f"reports/{n}-1.json")[0], {"writer": n})
        self.assertFalse(self.service.calls)

    def test_unknown_checkpoint_failure_is_never_retried(self):
        transport = self.service.github.transport
        attempts = []
        def timed_out(url, token, body=None, method=None):
            if method == "PUT":
                attempts.append(url)
                raise TimeoutError("private error")
            return transport(url, token, body, method)
        self.service.github.transport = timed_out
        with self.assertRaises(TimeoutError):
            self.state.checkpoint("1-1", {})
        self.assertEqual(len(attempts), 1)

    def test_exhausted_ledger_conflicts_preserve_operation_and_never_admit_spending(self):
        before = self.state.read_ledger()
        self.service.branch_conflicts = 100
        with patch("threat_review.state.conflict_backoff"), self.assertRaises(BudgetStopped) as caught:
            self.state.reserve(12, "1-1", "normal", 100_000)
        self.assertEqual(self.state.read_ledger(), before)
        self.assertEqual(caught.exception.diagnostic, {
            "code": "STATE_WRITE_FAILED", "service": "github", "operation": "ledger",
            "http_status": 409, "write_attempts": WRITE_ATTEMPTS})

    def test_atomic_reservations_for_same_run_over_real_http(self):
        # Both clients read the SAME ledger version before either writes it.
        barrier = threading.Barrier(2)
        local = threading.local()
        original = self.state.read
        def read(path):
            value = original(path)
            if path == "ledger.json" and not getattr(local, "waited", False):
                local.waited = True
                barrier.wait(timeout=5)
            return value
        self.state.read = read
        def reserve(_):
            try:
                return self.state.reserve(12, "1-1", "normal", 700_000)
            except BudgetStopped:
                return None
        with ThreadPoolExecutor(2) as pool:
            accepted = list(pool.map(reserve, range(2)))
        self.assertEqual(sum(x is not None for x in accepted), 1)
        self.assertGreaterEqual(self.service.conflicts, 1)
        self.assertEqual(sum(r["charge"] for r in original("ledger.json")[0]["requests"].values()), 700_000)

    def test_repository_and_pr_limits_include_other_runs(self):
        for index in range(5):
            self.state.reserve(12, f"{index}-1", "normal", 1_000_000)
        with self.assertRaisesRegex(BudgetStopped, "pr_day"):
            self.state.reserve(12, "6-1", "normal", 1)
        for pr in range(20, 24):
            self.state.reserve(pr, f"{pr}-1", "deep", 3_000_000)
            self.state.reserve(pr, f"{pr}-2", "deep", 2_000_000)
        with self.assertRaises(BudgetStopped):
            self.state.reserve(25, "30-1", "normal", 1)

    def test_unknown_reservations_do_not_expire_at_midnight(self):
        old = datetime(2026, 9, 1, tzinfo=timezone.utc)
        for index in range(5):
            self.state.reserve(12, f"{index}-1", "normal", 1_000_000, old)
        with self.assertRaisesRegex(BudgetStopped, "pr_day"):
            self.state.reserve(12, "6-1", "normal", 1)

    def test_actual_usage_reconciles_and_overrun_halts_future_calls(self):
        ticket = self.state.reserve(12, "1-1", "normal", 100_000)
        self.state.settle(ticket, 20_000)
        self.state.settle(ticket, 20_000)  # idempotent
        with self.assertRaises(BudgetStopped):
            self.state.settle(ticket, 0)
        second = self.state.reserve(12, "1-1", "normal", 100_000)
        self.state.settle(second, 200_000)
        with self.assertRaisesRegex(BudgetStopped, "circuit"):
            self.state.reserve(13, "2-1", "normal", 1)

    def test_pilot_admits_only_ten_unique_prs(self):
        for pr in range(10):
            self.state.reserve(pr, f"{pr}-1", "normal", 1)
        self.state.reserve(0, "100-1", "normal", 1)
        with self.assertRaisesRegex(BudgetStopped, "Ten-PR"):
            self.state.reserve(10, "101-1", "normal", 1)

    def test_cache_only_prs_also_count_toward_pilot(self):
        for pr in range(10):
            self.state.admit(pr)
        self.state.admit(0)
        with self.assertRaisesRegex(BudgetStopped, "Ten-PR"):
            self.state.admit(10)
        self.assertFalse(self.state.read("ledger.json")[0]["requests"])

    def test_daily_mode_continues_existing_pilot_without_resetting_history(self):
        old = datetime(2026, 9, 1, tzinfo=timezone.utc)
        for pr in range(10):
            ticket = self.state.reserve(pr, f"{pr}-1", "deep", 2_500_000, old)
            self.state.settle(ticket, 2_500_000)
        before = self.state.read("ledger.json")[0]
        daily = State(self.service.github, "daily")
        daily.admit(12)
        daily.reserve(12, "100-1", "normal", 1_000_000)
        after = daily.read("ledger.json")[0]
        for ticket, row in before["requests"].items():
            self.assertEqual(after["requests"][ticket], row)
        self.assertEqual(after["prs"], before["prs"] + [12])
        with self.assertRaisesRegex(BudgetStopped, "Ten-PR"):
            self.state.reserve(13, "101-1", "normal", 1)

    def test_daily_mode_preserves_all_four_spending_caps(self):
        daily = State(self.service.github, "daily")
        daily.reserve(12, "1-1", "normal", 1_000_000)
        with self.assertRaisesRegex(BudgetStopped, "normal"):
            daily.reserve(12, "1-1", "normal", 1)
        daily.reserve(12, "1-1", "deep", 3_000_000)
        with self.assertRaisesRegex(BudgetStopped, "deep"):
            daily.reserve(12, "1-1", "deep", 1)
        daily.reserve(12, "2-1", "normal", 1_000_000)
        with self.assertRaisesRegex(BudgetStopped, "pr_day"):
            daily.reserve(12, "3-1", "normal", 1)
        for pr in range(20, 24):
            daily.reserve(pr, f"{pr}-1", "deep", 3_000_000)
            daily.reserve(pr, f"{pr}-2", "deep", 2_000_000)
        with self.assertRaisesRegex(BudgetStopped, "repo_day"):
            daily.reserve(24, "24-1", "normal", 1)

    def test_daily_mode_retains_old_unknown_charges_and_circuit_breaker(self):
        old = datetime(2026, 9, 1, tzinfo=timezone.utc)
        daily = State(self.service.github, "daily")
        for index in range(5):
            daily.reserve(12, f"{index}-1", "normal", 1_000_000, old)
        with self.assertRaisesRegex(BudgetStopped, "pr_day"):
            daily.reserve(12, "100-1", "normal", 1)
        ticket = daily.reserve(13, "101-1", "normal", 1)
        daily.settle(ticket, 2)
        with self.assertRaisesRegex(BudgetStopped, "circuit"):
            daily.reserve(14, "102-1", "normal", 1)

    def test_invalid_budget_mode_cannot_enable_spending(self):
        before = self.state.read("ledger.json")
        for mode in (None, "", "unlimited", "DAILY", True):
            with self.subTest(mode=mode), self.assertRaisesRegex(BudgetStopped, "Invalid review budget mode"):
                State(self.service.github, mode)
        self.assertEqual(self.state.read("ledger.json"), before)

    def test_missing_or_unwritable_ledger_fails_closed(self):
        self.service.fail_write = True
        with self.assertRaises(APIError):
            self.state.reserve(12, "1-1", "normal", 1)
        self.service.files.pop("ledger.json")
        with self.assertRaises(BudgetStopped):
            self.state.reserve(12, "1-1", "normal", 1)

    def test_invalid_usage_is_not_accepted_as_zero(self):
        for value in (None, True, -1, "NaN", "Infinity", "bad"):
            with self.subTest(value=value), self.assertRaises((ValueError, ArithmeticError)):
                microdollars(value)
        self.assertEqual(microdollars("0.0000001"), 1)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        self.service = LocalService()
        self.addCleanup(self.service.close)
        self.limit = 25
        self.credit = {"total_credits": 25, "total_usage": 0}
        self.reads = []

    def funding(self, url, key):
        self.assertEqual(key, "synthetic")
        self.assertIn(url, ("https://openrouter.ai/api/v1/key", "https://openrouter.ai/api/v1/credits"))
        self.reads.append(url)
        return {"data": {"limit_remaining": self.limit} if url.endswith("/key") else self.credit}

    def test_preflight_verifies_real_state_io_without_changing_spend(self):
        before = self.service.state.read("ledger.json")
        preflight(self.service.state, "synthetic", self.funding)
        self.assertEqual(self.service.state.read("ledger.json"), before)
        self.assertEqual(self.service.state.read("preflight.json")[0]["paid_requests"], 0)
        self.assertFalse(self.service.calls)
        self.assertEqual(len(self.reads), 2)

    def test_preflight_rejects_exhausted_pilot_without_changing_ledger(self):
        for pr in range(10):
            self.service.state.admit(pr)
        before = self.service.state.read("ledger.json")
        with self.assertRaisesRegex(ReviewUnavailable, "Capacity: Ten-PR"):
            preflight(self.service.state, "synthetic", self.funding)
        self.assertEqual(self.service.state.read("ledger.json"), before)
        daily = State(self.service.github, "daily")
        preflight(daily, "synthetic", self.funding)
        self.assertEqual(daily.read("ledger.json"), before)
        self.assertFalse(self.service.calls)

    def test_preflight_requires_normal_attempt_capacity_including_unknown_charges(self):
        daily = State(self.service.github, "daily")
        old = datetime(2026, 9, 1, tzinfo=timezone.utc)
        for pr in range(5):
            daily.reserve(pr, f"{pr}-1", "deep", 3_000_000, old)
            daily.reserve(pr, f"{pr}-2", "deep", 2_000_000, old)
        before = daily.read("ledger.json")
        with self.assertRaisesRegex(ReviewUnavailable, "Capacity: repo_day"):
            preflight(daily, "synthetic", self.funding)
        self.assertEqual(daily.read("ledger.json"), before)
        # Only evidence-based settlement releases old reservations.
        for ticket in before[0]["requests"]:
            daily.settle(ticket, 0)
        preflight(daily, "synthetic", self.funding)
        self.assertFalse(self.service.calls)

    def test_preflight_rejects_invalid_or_full_ledger_in_daily_mode(self):
        daily = State(self.service.github, "daily")
        for rows in ({"broken": {}}, {str(i): {"charge": 0, "settled": True,
                      "day": "2026-09-01", "pr": 1, "run": str(i), "tier": "normal"}
                      for i in range(1000)}):
            daily.mutate(lambda ledger: ledger.update(requests=rows))
            with self.assertRaisesRegex(ReviewUnavailable, "Capacity:"):
                preflight(daily, "synthetic", self.funding)
        self.assertFalse(self.service.calls)

    def test_exhausted_key_and_account_are_distinct_failures(self):
        self.limit = 0
        with self.assertRaisesRegex(ReviewUnavailable, "key spending limit is exhausted"):
            preflight(self.service.state, "synthetic", self.funding)
        self.limit = None
        self.credit["total_usage"] = 25
        with self.assertRaisesRegex(ReviewUnavailable, "account has no remaining credits"):
            preflight(self.service.state, "synthetic", self.funding)
        self.assertFalse(self.service.calls)

    def test_funding_checked_even_when_state_writer_is_rejected(self):
        self.service.fail_write = True
        self.limit = 0
        with self.assertRaisesRegex(ReviewUnavailable, "Storage:.*403.*Funding:.*exhausted"):
            preflight(self.service.state, "synthetic", self.funding)

    def test_unsigned_writer_and_missing_ledger_fail_preflight(self):
        self.service.verified = False
        with self.assertRaisesRegex(ReviewUnavailable, "signature is not verified"):
            preflight(self.service.state, "synthetic", self.funding)
        self.service.files.pop("ledger.json")
        with self.assertRaisesRegex(ReviewUnavailable, "ledger is not initialized"):
            preflight(self.service.state, "synthetic", self.funding)

    def test_invalid_funding_never_claims_readiness(self):
        for value in (True, "NaN", "Infinity", "invalid"):
            self.limit = value
            with self.subTest(value=value), self.assertRaisesRegex(ReviewUnavailable, "funding response is invalid"):
                preflight(self.service.state, "synthetic", self.funding)

    def test_public_preflight_output_omits_funding_details(self):
        output = io.StringIO()
        with patch.dict("os.environ", {"GITHUB_REPOSITORY": "example/repo", "GH_TOKEN": "synthetic",
                                       "OPENROUTER_API_KEY": "synthetic"}), redirect_stdout(output):
            with patch("threat_review.preflight.check", side_effect=ReviewUnavailable("private funding detail")):
                with self.assertRaises(SystemExit) as caught:
                    runpy.run_path(str(Path(__file__).with_name("threat-review-preflight.py")), run_name="__main__")
        self.assertEqual(caught.exception.code, 1)
        self.assertIn("Preflight failed", output.getvalue())
        self.assertNotIn("private funding detail", output.getvalue())


class ScanTests(unittest.TestCase):
    def setUp(self):
        self.service = LocalService()
        self.addCleanup(self.service.close)
        self.files = complete_files(fixtures.FakeGitHub(), fixtures.FILES, fixtures.BASE, fixtures.HEAD)
        self.context = ThreatContext(fixtures.THREAT)
        self.checkpoints = []
        self.run_number = 0

    def scan(self, context=None, base=fixtures.BASE, force=False):
        self.run_number += 1
        context = context or self.context
        paid = PaidCalls(self.service.state, 12, f"{self.run_number}-1", "synthetic", context.prefix(), self.service.transport)
        scan = Scanner(context, self.files, self.service.state, paid,
                       lambda snapshot: self.checkpoints.append(copy.deepcopy(snapshot)), base)
        return scan.run(force), scan

    def test_sonnet_first_then_only_risky_depth_and_stable_prompt_caching(self):
        result, _ = self.scan()
        self.assertEqual([b["model"] for b in self.service.calls], [SONNET, SONNET, OPUS])
        self.assertTrue(result["integration_completed"])
        self.assertEqual(result["covered_units"], result["total_units"])
        self.assertFalse(result["errors"])
        self.assertTrue(any(s["integration_completed"] and s["requests"] == 2 for s in self.checkpoints))
        for body in self.service.calls:
            self.assertEqual(body["max_tokens"], 4096)
            self.assertFalse(body["provider"]["allow_fallbacks"])
            self.assertIn("max_price", body["provider"])
            self.assertIn("cache_control", body["messages"][0]["content"][0])
        self.assertEqual(self.service.calls[0]["messages"][0], self.service.calls[1]["messages"][0])

    def test_low_risk_clean_change_does_not_call_expensive_models(self):
        self.files[0]["filename"] = "docs/guide.md"
        result, _ = self.scan()
        self.assertEqual([b["model"] for b in self.service.calls], [SONNET, SONNET])
        self.assertFalse(result["findings"])

    @staticmethod
    def change_response(response, **changes):
        result = json.loads(response["choices"][0]["message"]["content"])
        result.update(changes)
        response["choices"][0]["message"]["content"] = json.dumps(result)
        return response

    def test_empty_analysis_gets_one_explicit_repair_with_identical_source(self):
        self.files[0]["filename"] = "docs/guide.md"
        def reply(body):
            response = self.service.completion(body)
            return self.change_response(response, analysis="") if len(self.service.calls) == 1 else response
        self.service.reply = reply
        result, _ = self.scan()
        self.assertFalse(result["errors"])
        self.assertTrue(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                              fixtures.HEAD, fixtures.BASE))
        self.assertEqual(len(self.service.calls), 3)
        first, repair = [json.loads(b["messages"][1]["content"]) for b in self.service.calls[:2]]
        self.assertEqual(repair.pop("response_repair")["code"], "BATCH_ANALYSIS_INVALID")
        self.assertEqual(first, repair)
        self.assertEqual(result["response_repairs"][0]["status"], "completed")
        self.assertEqual(result["response_repairs"][0]["analysis_characters"], 0)
        self.assertTrue(any(s.get("response_repairs") for s in self.checkpoints))

    def test_repair_retains_original_findings_and_uncertainty(self):
        def reply(body):
            response = self.service.completion(body)
            if len(self.service.calls) == 1:
                return self.change_response(response, analysis=" ", findings=[fixtures.FINDING],
                                            needs_deeper_review=True)
            return response
        self.service.reply = reply
        result, _ = self.scan()
        self.assertFalse(result["errors"])
        self.assertEqual(result["findings"][0]["title"], fixtures.FINDING["title"])
        self.assertTrue(any(s["findings"] and s["covered_units"] == 0 for s in self.checkpoints))
        integration = next(json.loads(b["messages"][1]["content"]) for b in self.service.calls
                           if json.loads(b["messages"][1]["content"])["stage"] == "integration")
        self.assertTrue(integration["units"][0]["needs_deeper_review"])
        self.assertEqual(integration["units"][0]["findings"], [fixtures.FINDING])
        self.assertFalse(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                               fixtures.HEAD, fixtures.BASE))

    def test_second_invalid_analysis_stops_without_another_repair(self):
        def reply(body):
            return self.change_response(self.service.completion(body, [fixtures.FINDING]), analysis="")
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 2)
        self.assertEqual(result["covered_units"], 0)
        self.assertTrue(result["findings"])
        self.assertEqual(result["diagnostics"][0]["code"], "BATCH_ANALYSIS_INVALID")
        self.assertEqual(result["response_repairs"][0]["status"], "failed")
        self.assertFalse(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                               fixtures.HEAD, fixtures.BASE))

    def test_repair_allowance_is_for_the_whole_scan(self):
        def reply(body):
            response = self.service.completion(body)
            return response if len(self.service.calls) == 2 else self.change_response(response, analysis="")
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 3)
        self.assertEqual(len(result["response_repairs"]), 1)
        self.assertTrue(result["errors"])
        self.assertFalse(result["integration_completed"])

    def test_invalid_citations_coverage_shape_and_decision_never_authorize_repair(self):
        for changes in ({"findings": [dict(fixtures.FINDING, line=999)]},
                        {"covered_units": None}, {"needs_deeper_review": "false"}):
            with self.subTest(changes=changes):
                self.service.calls.clear()
                self.service.reply = lambda body: self.change_response(
                    self.service.completion(body), analysis="", **changes)
                result, _ = self.scan()
                self.assertEqual(len(self.service.calls), 1)
                self.assertEqual(result["response_repairs"], [])
                self.assertTrue(result["errors"])

    def test_integration_cannot_confuse_replayed_source_ids_with_primary_ids(self):
        self.files[0]["filename"] = "docs/guide.md"
        wrong = False
        def reply(body):
            nonlocal wrong
            sent = json.loads(body["messages"][1]["content"])
            response = self.service.completion(body)
            if sent["stage"] == "integration":
                self.assertEqual(body["response_format"]["json_schema"]["schema"]["properties"]
                                 ["covered_units"]["items"]["enum"], [u["id"] for u in sent["units"]])
                self.assertTrue(all("id" not in u for u in sent["integration_source"]["units"]))
                if not wrong:
                    wrong = True
                    return self.change_response(response, covered_units=[u["source_id"] for u in
                                                                          sent["integration_source"]["units"]])
            return response
        self.service.reply = reply
        result, _ = self.scan()
        self.assertFalse(result["errors"])
        self.assertTrue(result["integration_completed"])
        self.assertEqual(len(self.service.calls), 3)
        self.assertEqual(result["response_repairs"][0]["code"], "BATCH_ACKNOWLEDGMENT_INVALID")
        self.assertEqual(result["response_repairs"][0]["status"], "completed")

    def test_repeated_wrong_integration_ids_remain_incomplete(self):
        def reply(body):
            sent = json.loads(body["messages"][1]["content"])
            response = self.service.completion(body)
            return (self.change_response(response, covered_units=["source-only-id"])
                    if sent["stage"] == "integration" else response)
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(result["covered_units"], result["total_units"])
        self.assertFalse(result["integration_completed"])
        self.assertEqual(len(self.service.calls), 3)
        self.assertEqual(result["response_repairs"][0]["status"], "failed")
        self.assertFalse(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                               fixtures.HEAD, fixtures.BASE))

    def test_analysis_and_acknowledgment_share_one_repair_allowance(self):
        def reply(body):
            sent = json.loads(body["messages"][1]["content"])
            response = self.service.completion(body)
            if len(self.service.calls) == 1:
                return self.change_response(response, analysis="")
            return (self.change_response(response, covered_units=[])
                    if sent["stage"] == "integration" else response)
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 3)
        self.assertEqual(len(result["response_repairs"]), 1)
        self.assertTrue(result["errors"])

    def test_wrong_source_ack_repair_preserves_citation_valid_findings(self):
        def reply(body):
            response = self.service.completion(body)
            if len(self.service.calls) == 1:
                return self.change_response(response, covered_units=[], findings=[fixtures.FINDING])
            return response
        self.service.reply = reply
        result, _ = self.scan()
        self.assertFalse(result["errors"])
        self.assertTrue(result["findings"])
        self.assertFalse(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                               fixtures.HEAD, fixtures.BASE))

    def test_identical_inputs_reuse_every_batch_without_spend(self):
        self.scan()
        count = len(self.service.calls)
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), count)
        self.assertEqual(result["requests"], 0)
        self.assertEqual(result["reused_batches"], count)

    def test_malformed_cache_stops_without_spend_or_prior_request_metadata(self):
        with patch.object(self.service.state, "cached", return_value={"findings": [], "PRIVATE": "secret"}):
            result, _ = self.scan()
        self.assertFalse(self.service.calls)
        self.assertFalse(result["integration_completed"])
        self.assertEqual(result["diagnostics"][0]["code"], "RESPONSE_FIELDS_INVALID")
        self.assertTrue(result["diagnostics"][0]["cache_hit"])
        self.assertNotIn("provider", result["diagnostics"][0])
        self.assertNotIn("secret", json.dumps(result))

    def test_sonnet_integration_receives_source_uncertainty(self):
        self.service.reply = lambda body: self.service.completion(
            body, uncertain=json.loads(body["messages"][1]["content"])["stage"] == "source")
        result, _ = self.scan()
        integration = json.loads(self.service.calls[1]["messages"][1]["content"])
        self.assertTrue(integration["units"][0]["needs_deeper_review"])
        self.assertFalse(result["errors"])

    def test_cross_file_uncertainty_is_not_cleared_by_independent_local_depth(self):
        self.files[0]["filename"] = "ordinary.py"
        def reply(body):
            stage = json.loads(body["messages"][1]["content"])["stage"]
            return self.service.completion(body, uncertain=body["model"] == SONNET and stage == "integration")
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual([b["model"] for b in self.service.calls], [SONNET, SONNET, OPUS])
        self.assertFalse(result["errors"])
        self.assertEqual(result["depth_batches_pending"], 0)
        self.assertTrue(result["manual_review_reasons"])
        self.assertFalse(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                               fixtures.HEAD, fixtures.BASE))

    def test_model_context_or_dependency_base_invalidates_cache(self):
        self.scan()
        result, _ = self.scan(base="d" * 40)
        self.assertEqual(result["reused_batches"], 0)
        result, _ = self.scan(context=ThreatContext(fixtures.THREAT + "    detail: now different\n"))
        self.assertEqual(result["reused_batches"], 0)
        with patch("threat_review.budget_scan.VERSION", "next-policy"):
            result, _ = self.scan()
        self.assertEqual(result["reused_batches"], 0)

    def test_integration_invalidates_even_when_source_summary_does_not_change(self):
        self.files[0]["filename"] = "ordinary.go"
        self.scan()
        count = len(self.service.calls)
        self.files[0]["head_text"] += "new_behavior()\n"
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls) - count, 2)
        self.assertEqual(result["reused_batches"], 0)

    def test_source_cache_cannot_cite_another_batchs_file(self):
        self.files = [{"filename": name, "status": "modified", "source_complete": True,
                       "base_text": "old\n" * 7000, "head_text": "new\n" * 7000,
                       "base_mode": "100644", "head_mode": "100644", "patch": ""}
                      for name in ("one.go", "two.go", "three.go")]
        def reply(body):
            sent = json.loads(body["messages"][1]["content"])
            visible = {u["metadata"]["file"] for u in sent["units"]}
            absent = next(f["filename"] for f in self.files if f["filename"] not in visible)
            return self.service.completion(body, [dict(fixtures.FINDING, file=absent, line=1)])
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 1)
        self.assertFalse(result["findings"])
        self.assertTrue(result["errors"])

    def test_split_patch_preserves_citations_on_both_sides_and_later_hunks(self):
        old = [f"-old {i}: " + "x" * 180 + "\n" for i in range(1, 1001)]
        new = [f"+new {i}: " + "y" * 180 + "\n" for i in range(1, 1001)]
        diff = "@@ -101,1000 +201,1000 @@\n" + "".join(old + new)
        diff += "@@ -2001,1 +3001,1 @@\n-old 1901: last\n+new 2801: last\n\\ No newline at end of file\n"
        files = [{"filename": "ordinary.go", "status": "modified", "patch": diff,
                  "additions": 1001, "deletions": 1001}]
        paid = PaidCalls(self.service.state, 12, "1-1", "synthetic", self.context.prefix(), self.service.transport)
        scanner = Scanner(self.context, files, self.service.state, paid, lambda _: None, fixtures.BASE)
        patches = [u for batch in scanner.source for u in batch if u.get("kind") == "patch"]
        self.assertGreater(len(patches), 2)
        for unit in patches:
            self.assertTrue(unit["text"].startswith("@@"))
            visible = scanner.batch_evidence("source", [unit])["ordinary.go"]["lines"]
            expected = {"base": set(), "head": set()}
            for line in unit["text"].splitlines():
                if line.startswith(("-old ", "+new ")):
                    number = int(line.split()[1].rstrip(":"))
                    expected["base" if line[0] == "-" else "head"].add(number + (100 if line[0] == "-" else 200))
            self.assertEqual(visible, expected)
        # A real response citing a continuation must survive validation/cache.
        unit = patches[1]
        finding = dict(fixtures.FINDING, file="ordinary.go", side="base",
                       line=min(scanner.batch_evidence("source", [unit])["ordinary.go"]["lines"]["base"]))
        self.service.reply = lambda body: self.service.completion(body, [finding])
        scanner.call(SONNET, "source", [unit])
        self.assertEqual(scanner.findings[0]["line"], finding["line"])

    def test_uncertain_low_risk_change_escalates_and_disagreement_gets_sol(self):
        self.files[0]["filename"] = "ordinary.go"
        finding = dict(fixtures.FINDING, file="ordinary.go", severity="medium")
        def reply(body):
            model = body["model"]
            return self.service.completion(body, [finding] if model == SONNET else [], uncertain=model == SONNET)
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual([b["model"] for b in self.service.calls], [SONNET, SONNET, OPUS, SOL, SOL])
        self.assertEqual(result["findings"][0]["models"], [SONNET])

    def test_actual_cost_overrun_preserves_findings_but_halts_spending(self):
        self.service.reply = lambda body: self.service.completion(body, [fixtures.FINDING], cost=2)
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 1)
        self.assertTrue(result["findings"])
        self.assertTrue(self.service.state.read("ledger.json")[0]["halted"])

    def test_final_reviewer_uncertainty_cannot_clear_merge(self):
        from threat_review.merge_policy import clean
        self.service.reply = lambda body: self.service.completion(body, [], uncertain=body["model"] == SOL)
        result, _ = self.scan(force=True)
        self.assertEqual([b["model"] for b in self.service.calls], [SONNET, SONNET, OPUS, SOL, SOL])
        self.assertEqual(result["depth_batches_pending"], 0)
        self.assertIn("Final reviewer requests further review", result["manual_review_reasons"][0])
        self.assertFalse(result["errors"])
        report = {"head": fixtures.HEAD, "base": fixtures.BASE, "review": result}
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertTrue(self.checkpoints[-1]["manual_review_reasons"])

    def test_sol_reconciles_local_uncertainty_before_final_decision(self):
        from threat_review.merge_policy import clean
        def reply(body):
            stage = json.loads(body["messages"][1]["content"])["stage"]
            return self.service.completion(body, uncertain=body["model"] == SOL and stage == "source")
        self.service.reply = reply
        result, _ = self.scan(force=True)
        self.assertFalse(result["manual_review_reasons"])
        self.assertTrue(clean({"head": fixtures.HEAD, "base": fixtures.BASE, "review": result},
                              fixtures.HEAD, fixtures.BASE))
        final = json.loads(self.service.calls[-1]["messages"][1]["content"])
        self.assertEqual(final["stage"], "integration")
        self.assertTrue(final["units"][0]["needs_deeper_review"])

    def test_failed_final_integration_is_incomplete_and_retains_advice(self):
        def reply(body):
            stage = json.loads(body["messages"][1]["content"])["stage"]
            if body["model"] == SOL and stage == "integration":
                return 503
            return self.service.completion(body, [fixtures.FINDING])
        self.service.reply = reply
        result, _ = self.scan(force=True)
        self.assertEqual(result["depth_batches_pending"], 1)
        self.assertTrue(result["findings"])
        self.assertTrue(result["errors"])
        self.assertEqual(result["diagnostics"][0]["http_status"], 503)
        self.assertEqual(result["diagnostics"][0]["stage"], "integration")

    def test_head_only_excerpt_receives_complete_change_coordinates(self):
        from threat_review.change_context import batch_changes
        self.files = [{"filename": "docs/guide.md", "status": "modified", "source_complete": True,
                       "base_text": "old\n" + "unchanged\n" * 9000,
                       "head_text": "new\n" + "unchanged\n" * 9000,
                       "patch": "@@ -1 +1 @@\n-old\n+new"}]
        scanner = Scanner(self.context, self.files, self.service.state, None, lambda _: None, fixtures.BASE)
        tail = next(u for b in scanner.source for u in b
                    if u.get("kind") == "head_text" and u["start_line"] > 1)
        context = batch_changes(scanner.changes, [tail])[0]
        self.assertEqual(context["changed_ranges"], {"base": [[1, 1]], "head": [[1, 1]]})
        self.assertTrue(context["range_map_complete"])
        self.assertIn("-old", context["patch_excerpt"])
        # Orientation includes line 1, but it grants no new citation permission.
        evidence = scanner.batch_evidence("source", [tail])
        self.assertNotIn(1, evidence["docs/guide.md"]["lines"]["head"])

    def test_invalid_json_diagnostic_is_correlated_and_has_no_response_text(self):
        def reply(body):
            response = self.service.completion(body)
            response["choices"][0]["message"]["content"] = '{"private-secret":\nINVALID}'
            return response
        self.service.reply = reply
        result, _ = self.scan()
        diagnostic = result["diagnostics"][0]
        self.assertEqual(diagnostic["code"], "RESPONSE_JSON_INVALID")
        self.assertEqual(diagnostic["line"], 2)
        self.assertEqual(diagnostic["model"], SONNET)
        self.assertEqual(len(diagnostic["batch_sha256"]), 64)
        self.assertNotIn("private-secret", json.dumps(result))
        self.assertEqual(len(self.service.calls), 1)

    def test_followup_push_reuses_unaffected_batches_but_reintegrates(self):
        self.files = [{"filename": name, "status": "modified", "source_complete": True,
                       "base_text": "old\n" * 7000, "head_text": "new\n" * 7000,
                       "base_mode": "100644", "head_mode": "100644", "patch": ""}
                      for name in ("one.go", "two.go", "three.go")]
        first, _ = self.scan()
        self.assertFalse(first["errors"])
        self.files[-1]["head_text"] += "different()\n"
        second, _ = self.scan()
        self.assertFalse(second["errors"])
        self.assertGreater(second["reused_batches"], 0)
        self.assertLess(second["requests"], first["requests"])
        self.assertTrue(second["integration_completed"])

    def test_later_failure_retains_source_findings_and_never_retries(self):
        def reply(body):
            if len(self.service.calls) == 1:
                return self.service.completion(body, [fixtures.FINDING])
            return 403
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 2)
        self.assertEqual(result["findings"][0]["title"], fixtures.FINDING["title"])
        self.assertIn("HTTP 403", result["errors"][0])
        self.assertGreater(result["unreconciled_reserved_usd"], 0)
        self.assertNotIn("never print", json.dumps(result))
        self.assertTrue(self.checkpoints[0]["findings"])

    def test_missing_cost_saves_findings_then_stops(self):
        def reply(body):
            result = self.service.completion(body, [fixtures.FINDING])
            del result["usage"]
            return result
        self.service.reply = reply
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 1)
        self.assertTrue(result["findings"])
        self.assertTrue(result["errors"])

    def test_critical_or_requested_second_opinion_is_independent(self):
        for force in (False, True):
            self.service.calls.clear()
            self.files[0]["filename"] = "crypto.go" if not force else "ordinary.go"
            result, _ = self.scan(force=force)
            self.assertIn(SOL, [b["model"] for b in self.service.calls])
            self.assertFalse(result["errors"])
            sol = next(b for b in self.service.calls if b["model"] == SOL)
            self.assertEqual(sol["model"], "openai/gpt-6.1-sol")
            self.assertEqual(sol["provider"]["max_price"], {"prompt": 2, "completion": 10, "request": 0})
            self.assertTrue(sol["response_format"]["json_schema"]["strict"])
            self.assertNotIn("cache_control", sol["messages"][0]["content"][0])
            self.assertNotIn("temperature", sol)

    def test_sonnet_55_reservation_and_provider_ceiling_match_selected_model(self):
        self.files[0]["filename"] = "ordinary.go"
        result, _ = self.scan()
        self.assertFalse(result["errors"])
        sonnet = self.service.calls[0]
        self.assertEqual(sonnet["model"], "anthropic/claude-sonnet-5.5")
        self.assertEqual(sonnet["provider"]["max_price"], {"prompt": 2, "completion": 10, "request": 0})

    def test_invalid_citations_are_never_saved_as_findings(self):
        self.service.reply = lambda body: self.service.completion(body, [dict(fixtures.FINDING, line=999)])
        result, _ = self.scan()
        self.assertFalse(result["findings"])
        self.assertTrue(result["errors"])

    def test_checkpoint_failure_stops_further_paid_work(self):
        paid = PaidCalls(self.service.state, 12, "1-1", "synthetic", self.context.prefix(), self.service.transport)
        def checkpoint(_):
            raise ReviewUnavailable("storage unavailable")
        scanner = Scanner(self.context, self.files, self.service.state, paid, checkpoint, fixtures.BASE)
        with self.assertRaises(ReviewUnavailable):
            scanner.run()
        self.assertEqual(len(self.service.calls), 1)

    def test_diagnostics_preserve_safe_validation_reasons_only(self):
        self.assertEqual(failure(ReviewUnavailable("Model returned an unknown threat reference")),
                         "Model returned an unknown threat reference")
        self.assertNotIn("private provider payload", failure(ValueError("private provider payload")))
        self.assertEqual(failure(APIError(422)), "Service returned HTTP 422; no automatic paid retry")

    def test_control_characters_cannot_spoof_report_text(self):
        text = plain("safe\u202eevil\u2066\x00\x1b@team\u200b")
        self.assertEqual(text, "safeevil@\u200bteam")


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        self.service = LocalService()
        self.addCleanup(self.service.close)
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/threat-model.yaml").write_text(fixtures.THREAT)
        self.env = {"GH_TOKEN": "synthetic", "OPENROUTER_API_KEY": "synthetic",
                    "GITHUB_RUN_ID": "123", "THREAT_REVIEW_ENABLED": "true"}
        self.github = fixtures.FakeGitHub()
        original_call = self.github.call
        def canonical_call(path, *args):
            if path == "/git/trees/" + "e" * 40:
                return {"tree": [{"path": "threat-model.yaml", "type": "blob", "mode": "100644", "sha": "f" * 40}]}
            if path == "/git/blobs/" + "f" * 40:
                raw = fixtures.THREAT.encode()
                return {"encoding": "base64", "size": len(raw), "content": base64.b64encode(raw).decode()}
            result = original_call(path, *args)
            if path == "/git/trees/" + "1" * 40:
                result = copy.deepcopy(result)
                result["tree"].append({"path": "docs", "type": "tree", "sha": "e" * 40})
            return result
        self.github.call = canonical_call
        def factory(*args, **kwargs):
            return PaidCalls(*args, **kwargs, transport=self.service.transport)
        self.factory = factory

    def run_review(self, event=fixtures.EVENT):
        return run(event, self.env, self.github, self.service.state, self.factory)

    def test_manual_github_rerun_hands_off_without_any_paid_work(self):
        self.env.update(GITHUB_RUN_ATTEMPT="2", THREAT_REVIEW_RESULT_FILE=str(self.root / "result.json"))
        self.github.files = lambda count: self.fail("A rerun must not start source collection")
        body = self.run_review()
        self.assertIn("MANUAL_SCAN_RERUN_DISABLED", body)
        self.assertIn("Human review required: CI did not complete", body)
        self.assertEqual(self.service.calls, [])
        report = json.loads((self.root / "result.json").read_text())
        self.assertEqual(report["run"], "123-2")
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))

    def test_scanner_runtime_is_bounded_and_ci_can_use_fifty_minutes(self):
        seconds = runpy.run_path(str(Path(__file__).with_name("threat-model-review.py")))["runtime_seconds"]
        self.assertEqual(seconds({}), 900)
        self.assertEqual(seconds({"THREAT_REVIEW_TIMEOUT_SECONDS": "3000"}), 3000)
        for invalid in ("0", "59", "3001", "unlimited", "1.5"):
            with self.subTest(invalid=invalid), self.assertRaises(ReviewUnavailable):
                seconds({"THREAT_REVIEW_TIMEOUT_SECONDS": invalid})

    def test_workload_ceiling_hands_off_at_the_exact_unadmitted_stage(self):
        body, report, diagnostic, requests = self.bedrock_run(
            self.bedrock_response, BEDROCK_SCAN_CALL_POLICY="workload", BEDROCK_SCAN_MAX_WORKLOAD_CALLS="2")
        self.assertEqual(len(requests), 1)
        self.assertIn("Human review required: CI did not complete", body)
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        failure = diagnostic["diagnostics"][0]
        self.assertEqual(failure["code"], "BEDROCK_WORKLOAD_LIMIT")
        self.assertEqual(failure["stage"], "integration")
        self.assertEqual(failure["phase"], "planning")
        self.assertNotIn("call", failure)  # do not misattribute the preceding source call
        self.assertEqual(diagnostic["bedrock_planned_calls"], 2)
        self.assertTrue(diagnostic["finished"])
        self.assertFalse(self.service.calls)

    def test_scan_continues_after_initial_checkpoint_conflict_without_repeating_provider_calls(self):
        self.service.branch_conflicts = 1
        self.service.conflict_path = "reports/123-1.json"
        body = self.run_review()
        self.assertIn("cross-file integration complete", body)
        self.assertEqual(self.service.conflicts, 1)
        identities = [(body["model"], json.loads(body["messages"][1]["content"])["stage"])
                      for body in self.service.calls]
        self.assertEqual(identities, [(SONNET, "source"), (SONNET, "integration"), (OPUS, "source")])

    def test_current_scanner_reads_canonical_context_from_pinned_base_blob(self):
        (self.root / "docs/threat-model.yaml").unlink()
        self.assertIn("cross-file integration complete", self.run_review())

    def test_missing_canonical_context_retains_comment_and_diagnostics_before_spend(self):
        original_call = self.github.call
        def missing_context(path, *args):
            if path == "/git/trees/" + "e" * 40:
                raise APIError(404)
            return original_call(path, *args)
        self.github.call = missing_context
        diagnostics = self.root / "diagnostics.json"
        self.env["THREAT_REVIEW_DIAGNOSTICS_FILE"] = str(diagnostics)
        body = self.run_review()
        self.assertIn("HTTP 404", body)
        self.assertIn("HTTP 404", self.github.posts[-1][1])
        self.assertEqual(self.service.calls, [])
        failure = json.loads(diagnostics.read_text())["diagnostics"][0]
        self.assertEqual(failure["phase"], "canonical_context")
        self.assertEqual(failure["http_status"], 404)

    def test_initial_conflict_exhaustion_is_diagnosed_before_any_provider_request(self):
        diagnostics = self.root / "diagnostics.json"
        self.env["THREAT_REVIEW_DIAGNOSTICS_FILE"] = str(diagnostics)
        self.service.branch_conflicts = 100
        self.service.conflict_path = "reports/123-1.json"
        with patch("threat_review.state.conflict_backoff"):
            self.run_review()
        self.assertEqual(self.service.calls, [])
        failure = json.loads(diagnostics.read_text())["diagnostics"][0]
        self.assertEqual(failure["phase"], "initial_checkpoint")
        self.assertEqual(failure["operation"], "report")
        self.assertEqual(failure["http_status"], 409)

    def test_runner_uses_trusted_daily_policy_for_funded_review_after_pilot(self):
        for pr in range(100, 110):
            self.service.state.admit(pr)
        self.env.update(THREAT_REVIEW_BUDGET_MODE="daily", THREAT_REVIEW_STATE_TOKEN="synthetic")
        with patch("threat_review.budget_runner.GitHub", return_value=self.service.github):
            result = run(fixtures.EVENT, self.env, self.github, paid_factory=self.factory)
        self.assertIn("cross-file integration complete", result)
        self.assertTrue(self.service.calls)
        self.assertGreater(len(self.service.state.read("ledger.json")[0]["prs"]), 10)

    def test_disabled_gate_keeps_previous_findings_without_any_spend(self):
        self.env.pop("THREAT_REVIEW_ENABLED")
        self.github.existing = {"id": 7, "body": "earlier useful finding"}
        self.run_review()
        self.assertFalse(self.service.calls)
        self.assertIn("earlier useful finding", self.github.posts[-1][1])
        self.assertIn("paused", self.github.posts[-1][1])

    def test_clean_first_run_comments_with_cost_coverage_and_history(self):
        result = self.run_review()
        self.assertIn("No actionable findings", self.github.posts[-1][1])
        self.assertIn("Cost this run", result)
        self.assertIn("cross-file integration complete", result)
        saved = self.service.state.read("reports/123-1.json")[0]
        self.assertEqual(saved["head"], fixtures.HEAD)
        self.assertTrue(saved["review"]["integration_completed"])

    def test_unwritable_diagnostics_do_not_destroy_report_or_original_failure(self):
        self.env["THREAT_REVIEW_DIAGNOSTICS_FILE"] = str(self.root)
        self.env["THREAT_REVIEW_RESULT_FILE"] = str(self.root / "result.json")
        self.service.reply = lambda body: 503
        errors = io.StringIO()
        with redirect_stderr(errors):
            body = self.run_review()
        self.assertIn("HTTP 503", body)
        report = json.loads((self.root / "result.json").read_text())
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertEqual(report["review"]["diagnostics"][0]["http_status"], 503)
        self.assertIn("DIAGNOSTICS_WRITE_FAILED", errors.getvalue())
        self.assertNotIn(str(self.root), errors.getvalue())

    def test_cli_result_write_failure_preserves_original_error_and_findings(self):
        blocked = self.root / "blocked-result"
        blocked.mkdir()
        event = self.root / "event.json"
        event.write_text(json.dumps(fixtures.EVENT))
        diagnostic_path = self.root / "diagnostics.json"
        self.env.update(GITHUB_EVENT_PATH=str(event), THREAT_REVIEW_RESULT_FILE=str(blocked),
                        THREAT_REVIEW_DIAGNOSTICS_FILE=str(diagnostic_path))
        self.service.reply = lambda body: (self.service.completion(body, [fixtures.FINDING])
                                          if len(self.service.calls) == 1 else 503)
        actual_run = lambda event, env: run(event, env, self.github, self.service.state, self.factory)
        output = io.StringIO()
        with patch.dict(os.environ, self.env), patch("threat_review.budget_runner.run", side_effect=actual_run), \
                patch("signal.signal"), patch("signal.alarm"), redirect_stdout(output), \
                self.assertRaises(SystemExit) as caught:
            runpy.run_path(str(Path(__file__).with_name("threat-model-review.py")), run_name="__main__")
        self.assertEqual(caught.exception.code, 1)
        diagnostic = json.loads(diagnostic_path.read_text())
        codes = [item["code"] for item in diagnostic["diagnostics"]]
        self.assertIn("OPENROUTER_API_ERROR", codes)
        self.assertIn("RESULT_WRITE_FAILED", codes)
        self.assertGreater(diagnostic["covered_units"], 0)
        self.assertIn("HTTP 503", output.getvalue())
        self.assertNotIn("setup or GitHub API failed", output.getvalue())
        saved = self.service.state.read("reports/123-1.json")[0]
        self.assertTrue(saved["review"]["findings"])
        self.assertFalse(clean(saved, fixtures.HEAD, fixtures.BASE))
    def test_progress_comment_precedes_source_collection(self):
        files = self.github.files
        def collect(count):
            self.assertTrue(self.github.posts)
            self.assertIn("Review in progress", self.github.posts[-1][1])
            self.assertFalse(self.service.calls)
            return files(count)
        self.github.files = collect
        self.run_review()

    def test_oversized_file_list_posts_compact_status_and_preserves_full_report(self):
        files = [{"filename": f"assets/{i:04d}/" + "x" * 100 + ".bin",
                  "status": "added", "source_complete": False} for i in range(1000)]
        publish = self.github.publish
        def bounded_publish(existing, body):
            if len(body) > COMMENT_LIMIT:
                raise APIError(422)
            return publish(existing, body)
        self.github.publish = bounded_publish
        self.service.reply = lambda body: 403
        with patch("threat_review.budget_runner.complete_files", return_value=files):
            self.run_review()
        body = self.github.posts[-1][1]
        self.assertLessEqual(len(body), COMMENT_LIMIT)
        self.assertIn("1000 file(s) requiring manual review", body)
        self.assertIn("Saved findings and earlier report", body)
        self.assertNotIn("No actionable findings", body)
        saved = self.service.state.read("reports/123-1.json")[0]["review"]
        self.assertEqual(saved["limited_files"], [f["filename"] for f in files])

    def test_uncertain_comment_creation_is_looked_up_before_retry(self):
        original = self.github.publish
        def publish(existing, body):
            original(existing, body)
            if existing is None:
                self.github.existing = {"id": 8, "body": body}
                raise ReviewUnavailable("POST response lost after creation")
            return dict(existing, body=body)
        self.github.publish = publish
        self.run_review()
        self.assertEqual(sum(old is None for old, body in self.github.posts), 1)
        self.assertEqual(self.github.posts[-1][0]["id"], 8)

    def test_head_changes_after_paid_work_still_preserve_durable_findings(self):
        def reply(body):
            self.github.stale = True
            return self.service.completion(body, [fixtures.FINDING])
        self.service.reply = reply
        self.run_review()
        saved = self.service.state.read("reports/123-1.json")[0]
        self.assertTrue(saved["review"]["findings"])
        self.assertEqual(len(self.service.calls), 1)
        self.assertNotIn(fixtures.FINDING["title"], self.github.posts[-1][1])

    def test_manual_deep_review_checks_current_permission(self):
        event = copy.deepcopy(fixtures.EVENT)
        event.update(review_depth="deep", sender={"login": "outsider"})
        self.github.call = lambda path: {"permission": "read"}
        self.run_review(event)
        self.assertFalse(self.service.calls)

    def bedrock_run(self, reply, **config):
        """Exercise the real transport adapter, scanner, state and rendering."""
        self.env.update(
            BEDROCK_SCAN_ENABLED="true", GITHUB_REPOSITORY="example/repo",
            BEDROCK_SCAN_PROFILES=json.dumps({
                name: f"arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/{name}"
                for name in ("sonnet", "opus", "sol")}),
            BEDROCK_SCAN_USAGE_FILE=str(self.root / "usage.jsonl"),
            THREAT_REVIEW_DIAGNOSTICS_FILE=str(self.root / "diagnostics.json"),
            THREAT_REVIEW_RESULT_FILE=str(self.root / "result.json"),
            **config)
        requests = []
        outer = self
        class Client:
            def converse(self, **request):
                requests.append(request)
                # Progress must already exist before a potentially killed call.
                progress = json.loads((outer.root / "diagnostics.json").read_text())
                outer.assertEqual(progress["active_request"]["phase"], "provider_call")
                return reply(request)
        def factory(*args, **kwargs):
            return BedrockCalls(*args, **kwargs, client=Client(), fallback_factory=self.factory)
        event = copy.deepcopy(fixtures.EVENT)
        event.update(review_depth="deep", sender={"login": "maintainer"})
        original = self.github.call
        self.github.call = lambda path: {"permission": "write"} if "/permission" in path else original(path)
        with patch("threat_review.bedrock.BedrockCalls", side_effect=factory):
            body = self.run_review(event)
        report = json.loads((self.root / "result.json").read_text())
        diagnostic = json.loads((self.root / "diagnostics.json").read_text())
        return body, report, diagnostic, requests

    @staticmethod
    def bedrock_response(request, uncertain=False):
        sent = json.loads(request["messages"][0]["content"][0]["text"])
        result = {"findings": [], "covered_units": [u["id"] for u in sent["units"]],
                  "analysis": "Synthetic complete analysis.", "needs_deeper_review": uncertain}
        return {"usage": {"inputTokens": 100, "outputTokens": 50}, "stopReason": "end_turn",
                "ResponseMetadata": {"RequestId": "12345678-1234-1234-1234-123456789abc"},
                "output": {"message": {"content": [{"text": json.dumps(result)}]}}}

    def test_bedrock_full_lifecycle_completes_final_integration_and_artifacts(self):
        body, report, diagnostic, requests = self.bedrock_run(self.bedrock_response)
        self.assertTrue(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertEqual(len(requests), 5)
        self.assertEqual([r["modelId"].rsplit("/", 1)[-1] for r in requests],
                         ["sonnet", "sonnet", "opus", "sol", "sol"])
        self.assertEqual(diagnostic["diagnostics"], [])
        self.assertEqual(diagnostic["active_request"]["phase"], "validated")
        saved = self.service.state.read("reports/123-1.json")[0]
        self.assertEqual(saved["review"], report["review"])
        self.assertNotIn("Review not completed", body)
        self.assertFalse(self.service.calls)

    def test_bedrock_analysis_repair_across_all_selected_models_and_stages(self):
        self.env["THREAT_REVIEW_REQUIRE_CLEARANCE"] = "true"  # fresh evidence for each case
        for alias, stage in (("sonnet", "source"), ("sonnet", "integration"), ("opus", "source"),
                             ("sol", "source"), ("sol", "integration")):
            with self.subTest(model=alias, stage=stage):
                damaged = False
                def reply(request):
                    nonlocal damaged
                    sent = json.loads(request["messages"][0]["content"][0]["text"])
                    response = self.bedrock_response(request)
                    if request["modelId"].endswith("/" + alias) and sent["stage"] == stage and not damaged:
                        damaged = True
                        result = json.loads(response["output"]["message"]["content"][0]["text"])
                        result["analysis"] = ""
                        response["output"]["message"]["content"][0]["text"] = json.dumps(result)
                    return response
                body, report, diagnostic, requests = self.bedrock_run(reply)
                self.assertTrue(damaged)
                self.assertEqual(len(requests), 6)
                self.assertTrue(clean(report, fixtures.HEAD, fixtures.BASE))
                self.assertEqual(diagnostic["response_repairs"][0]["status"], "completed")
                self.assertEqual(diagnostic["response_repairs"][0]["request_id"],
                                 "12345678-1234-1234-1234-123456789abc")
                self.assertIn("Response repair: 1/1 completed", body)
                self.assertFalse(self.service.calls)

    def test_bedrock_analysis_repair_cannot_exceed_call_cap(self):
        def reply(request):
            response = self.bedrock_response(request)
            result = json.loads(response["output"]["message"]["content"][0]["text"])
            result.update(analysis="", findings=[fixtures.FINDING])
            response["output"]["message"]["content"][0]["text"] = json.dumps(result)
            return response
        body, report, diagnostic, requests = self.bedrock_run(reply, BEDROCK_SCAN_MAX_CALLS="1")
        self.assertEqual(len(requests), 1)
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertEqual(diagnostic["diagnostics"][0]["code"], "BEDROCK_CALL_LIMIT")
        self.assertTrue(report["review"]["findings"])
        self.assertEqual(diagnostic["response_repairs"][0]["status"], "failed")
        self.assertFalse(self.service.calls)

    def test_native_accounting_failures_retain_valid_findings_and_block_clearance(self):
        self.env["THREAT_REVIEW_REQUIRE_CLEARANCE"] = "true"
        original_record = BedrockCalls.record
        for cause, code in (("missing", "BEDROCK_USAGE_MISSING"), ("write", "BEDROCK_USAGE_RECORD_FAILED")):
            with self.subTest(cause=cause):
                def record(adapter, **fields):
                    if cause == "write" and fields.get("event") == "response":
                        raise OSError("PRIVATE_ACCOUNTING_ERROR")
                    return original_record(adapter, **fields)
                def reply(request):
                    response = self.bedrock_response(request)
                    result = json.loads(response["output"]["message"]["content"][0]["text"])
                    result["findings"] = [fixtures.FINDING]
                    response["output"]["message"]["content"][0]["text"] = json.dumps(result)
                    if cause == "missing":
                        response["usage"] = {}
                    return response
                with patch.object(BedrockCalls, "record", record):
                    body, report, diagnostic, requests = self.bedrock_run(reply)
                self.assertEqual(len(requests), 1)
                self.assertTrue(report["review"]["findings"])
                self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
                self.assertTrue(any(d["code"] == code and d["stage"] == "source"
                                    for d in diagnostic["diagnostics"]))
                self.assertEqual(report["review"]["bedrock_unknown_usage"], 1)
                self.assertNotIn("PRIVATE_ACCOUNTING_ERROR", json.dumps(diagnostic))
                self.assertFalse(self.service.calls)

    def test_analysis_repair_stops_before_transport_after_failed_checkpoint(self):
        def reply(request):
            response = self.bedrock_response(request)
            result = json.loads(response["output"]["message"]["content"][0]["text"])
            result.update(analysis="", findings=[fixtures.FINDING])
            response["output"]["message"]["content"][0]["text"] = json.dumps(result)
            self.service.fail_write = True
            return response
        body, report, diagnostic, requests = self.bedrock_run(reply)
        self.assertEqual(len(requests), 1)
        self.assertTrue(report["review"]["findings"])
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertEqual(diagnostic["diagnostics"][0]["code"], "STATE_WRITE_FAILED")
        self.assertFalse(self.service.calls)

    def test_interrupted_repair_does_not_reuse_original_request_metadata(self):
        count = 0
        def reply(request):
            nonlocal count
            count += 1
            if count == 2:
                raise KeyboardInterrupt("PRIVATE_INTERRUPTED_REPAIR")
            response = self.bedrock_response(request)
            result = json.loads(response["output"]["message"]["content"][0]["text"])
            result["analysis"] = ""
            response["output"]["message"]["content"][0]["text"] = json.dumps(result)
            return response
        with self.assertRaises(KeyboardInterrupt):
            self.bedrock_run(reply)
        diagnostic = json.loads((self.root / "diagnostics.json").read_text())
        active = diagnostic["active_request"]
        self.assertEqual(active["phase"], "provider_call")
        self.assertEqual(active["response_attempt"], 2)
        self.assertNotIn("request_id", active)
        self.assertNotIn("stop_reason", active)
        self.assertNotIn("call", active)
        self.assertEqual(diagnostic["response_repairs"][0]["request_id"],
                         "12345678-1234-1234-1234-123456789abc")
        self.assertNotIn("PRIVATE_INTERRUPTED_REPAIR", json.dumps(diagnostic))

    def test_closed_pr_has_a_distinct_stop_reason_before_any_model_call(self):
        collect = self.github.files
        pull = self.github.pull
        def files(count):
            result = collect(count)
            self.github.pull = lambda: dict(pull(), state="closed", merged=True)
            return result
        self.github.files = files
        self.env["THREAT_REVIEW_DIAGNOSTICS_FILE"] = str(self.root / "diagnostics.json")
        body = self.run_review()
        self.assertIn("PR closed or merged", body)
        self.assertFalse(self.service.calls)
        saved = self.service.state.read("reports/123-1.json")[0]
        self.assertEqual(saved["review"]["diagnostics"][0]["code"], "PR_CLOSED")
        self.assertFalse(clean(saved, fixtures.HEAD, fixtures.BASE))

    def assert_fallback_accounting_halts_recovered_primary(self, mode):
        def fallback(body):
            response = self.service.completion(body, [fixtures.FINDING], cost=2 if mode == "overrun" else 0.01)
            if mode == "missing":
                response["usage"].pop("cost")
            return response
        self.service.reply = fallback
        if mode == "reconciliation":
            def failed_settlement(*args):
                raise APIError(403)
            self.service.state.settle = failed_settlement
        native_calls = 0
        def reply(request):
            nonlocal native_calls
            native_calls += 1
            if native_calls == 1:
                error = RuntimeError("synthetic unavailability")
                error.response = {"Error": {"Code": "ServiceUnavailableException"}}
                raise error
            return self.bedrock_response(request)  # recovery must not bypass stop
        body, report, diagnostic, requests = self.bedrock_run(reply)
        self.assertEqual(len(requests), 1)
        self.assertEqual(len(self.service.calls), 1)
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertFalse(report["review"]["integration_completed"])
        self.assertEqual(report["review"]["findings"][0]["title"], fixtures.FINDING["title"])
        saved = self.service.state.read("reports/123-1.json")[0]
        self.assertEqual(saved["review"]["findings"], report["review"]["findings"])
        self.assertIn(fixtures.FINDING["title"], body)
        self.assertEqual(diagnostic["diagnostics"][0]["code"], "REVIEW_BUDGET_STOPPED")

    def test_missing_fallback_cost_stops_recovered_bedrock_and_retains_findings(self):
        self.assert_fallback_accounting_halts_recovered_primary("missing")

    def test_failed_fallback_settlement_stops_recovered_bedrock_and_retains_findings(self):
        self.assert_fallback_accounting_halts_recovered_primary("reconciliation")

    def test_fallback_overrun_stops_recovered_bedrock_and_retains_findings(self):
        self.assert_fallback_accounting_halts_recovered_primary("overrun")

    def test_bedrock_truncation_preserves_code_request_identity_and_no_clearance(self):
        def reply(request):
            response = self.bedrock_response(request)
            response["stopReason"] = "max_tokens"
            response["usage"]["outputTokens"] = 4096
            response["output"]["message"]["content"][0]["text"] = "PRIVATE_TRUNCATED_RESPONSE"
            return response
        body, report, diagnostic, requests = self.bedrock_run(reply)
        self.assertEqual(len(requests), 1)
        self.assertFalse(self.service.calls)  # no fallback/resampling
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertIn("Review not completed", body)
        failure = diagnostic["diagnostics"][0]
        self.assertEqual(failure["code"], "BEDROCK_RESPONSE_INCOMPLETE")
        self.assertEqual(failure["stop_reason"], "max_tokens")
        self.assertEqual(failure["request_id"], "12345678-1234-1234-1234-123456789abc")
        self.assertNotIn("PRIVATE_TRUNCATED_RESPONSE", json.dumps(diagnostic))

    def test_bedrock_final_uncertainty_is_complete_but_never_clears(self):
        def reply(request):
            stage = json.loads(request["messages"][0]["content"][0]["text"])["stage"]
            return self.bedrock_response(request, request["modelId"].endswith("/sol") and stage == "integration")
        body, report, diagnostic, requests = self.bedrock_run(reply)
        self.assertEqual(len(requests), 5)
        self.assertIn("Scan completed; human review required", body)
        self.assertNotIn("Review not completed", body)
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertFalse(diagnostic["diagnostics"])

    def test_bedrock_call_cap_stops_before_final_integration_without_clearance(self):
        body, report, diagnostic, requests = self.bedrock_run(
            self.bedrock_response, BEDROCK_SCAN_MAX_CALLS="4")
        self.assertEqual(len(requests), 4)
        self.assertEqual(report["review"]["depth_batches_pending"], 1)
        self.assertEqual(diagnostic["diagnostics"][0]["code"], "BEDROCK_CALL_LIMIT")
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertFalse(self.service.calls)

    def test_remote_checkpoint_failure_preserves_local_diagnostics_and_halts(self):
        def reply(request):
            self.service.fail_write = True
            return self.bedrock_response(request)
        body, report, diagnostic, requests = self.bedrock_run(reply)
        self.assertEqual(len(requests), 1)
        self.assertFalse(clean(report, fixtures.HEAD, fixtures.BASE))
        self.assertTrue(diagnostic["diagnostics"])
        self.assertEqual(diagnostic["active_request"]["model"], SONNET)
        self.assertNotIn("secret provider payload", json.dumps(diagnostic))

    def test_interrupted_provider_call_leaves_content_free_progress(self):
        def interrupted(request):
            raise KeyboardInterrupt("PRIVATE_INTERRUPTION")
        with self.assertRaises(KeyboardInterrupt):
            self.bedrock_run(interrupted)
        diagnostic = json.loads((self.root / "diagnostics.json").read_text())
        self.assertEqual(diagnostic["active_request"]["phase"], "provider_call")
        self.assertEqual(diagnostic["active_request"]["model"], SONNET)
        self.assertFalse(diagnostic["integration_completed"])
        self.assertNotIn("PRIVATE_INTERRUPTION", json.dumps(diagnostic))


if __name__ == "__main__":
    unittest.main()
