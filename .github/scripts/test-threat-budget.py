#!/usr/bin/env python3
"""Offline HTTP integration tests for budgets, reuse, escalation and delivery."""
import base64
import copy
from contextlib import redirect_stdout
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import runpy
import threading
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit

from threat_review.budget_runner import run
from threat_review.budget_scan import Scanner
from threat_review.client import APIError, GitHub, ReviewUnavailable, request_json
from threat_review.context import ThreatContext, SONNET, OPUS, SOL
from threat_review.paid import PaidCalls, microdollars
from threat_review.preflight import check as preflight
from threat_review.report import COMMENT_LIMIT, plain
from threat_review.source import complete_files
from threat_review.state import State, BudgetStopped, fresh

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
                    old = service.files.get(path)
                    if service.fail_write:
                        return self.send(403, {"message": "secret provider payload"})
                    if (old and body.get("sha") != old["sha"]) or (not old and "sha" in body):
                        service.conflicts += 1
                        return self.send(409, {})
                    raw = base64.b64decode(body["content"])
                    sha = hashlib.sha1(raw).hexdigest()
                    service.files[path] = {"sha": sha, "encoding": "base64", "size": len(raw), "content": body["content"]}
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
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
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

    def test_identical_inputs_reuse_every_batch_without_spend(self):
        self.scan()
        count = len(self.service.calls)
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), count)
        self.assertEqual(result["requests"], 0)
        self.assertEqual(result["reused_batches"], count)

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
        self.assertEqual([b["model"] for b in self.service.calls], [SONNET, SONNET, OPUS, SOL])
        self.assertEqual(result["findings"][0]["models"], [SONNET])

    def test_actual_cost_overrun_preserves_findings_but_halts_spending(self):
        self.service.reply = lambda body: self.service.completion(body, [fixtures.FINDING], cost=2)
        result, _ = self.scan()
        self.assertEqual(len(self.service.calls), 1)
        self.assertTrue(result["findings"])
        self.assertTrue(self.service.state.read("ledger.json")[0]["halted"])

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
        def factory(*args, **kwargs):
            return PaidCalls(*args, **kwargs, transport=self.service.transport)
        self.factory = factory

    def run_review(self, event=fixtures.EVENT):
        return run(event, self.root, self.env, self.github, self.service.state, self.factory)

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


if __name__ == "__main__":
    unittest.main()
