#!/usr/bin/env python3
"""Cloud-free regressions for advisory outcomes and trusted-data boundaries."""
import copy
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit
from unittest.mock import patch
from urllib.error import HTTPError

from threat_review.client import GitHub, PrivateAdvisories, NoRedirects, ReviewUnavailable, request_json
from threat_review.report import render
from threat_review.review import prepare, review, validate_findings
from threat_review.runner import COMPLETED, UNAVAILABLE, SKIPPED, run, summarize

HEAD, BASE = "a" * 40, "b" * 40
THREAT = "threats:\n  - id: T-001\n    affected_files: [coordinator/auth.go]\n"
FILES = [{"filename": "coordinator/auth.go", "status": "modified", "additions": 1,
          "deletions": 1, "patch": "@@ -4,2 +4,2 @@\n-checkAuth()\n+allowAll()\n next()"}]
FINDING = {"severity": "high", "title": "Missing authorization", "detail": "An unauthenticated request reaches the operation; retain the authorization check.",
           "file": "coordinator/auth.go", "line": 4, "side": "head", "threat_ids": ["T-001"]}
EVENT = {"repository": {"full_name": "example/repo"}, "pull_request": {
    "number": 12, "head": {"sha": HEAD}, "base": {"sha": BASE}, "draft": False}}


def completion(findings, reason="stop"):
    return {"choices": [{"finish_reason": reason, "message": {"content": json.dumps({"findings": findings})}}]}


class ReviewTests(unittest.TestCase):
    def test_all_files_sent_even_outside_existing_threat_patterns(self):
        files = copy.deepcopy(FILES)
        files[0]["filename"] = "new-component/new-auth.go"
        text, evidence, limits = prepare(THREAT, files)
        self.assertIn("allowAll()", text)
        self.assertIn("new-component/new-auth.go", evidence)
        self.assertEqual(limits, [])

    def test_deleted_and_renamed_files_have_base_evidence(self):
        file = {"filename": "new.go", "previous_filename": "old.go", "status": "renamed",
                "additions": 0, "deletions": 1, "patch": "@@ -7 +7,0 @@\n-checkAuth()"}
        _, evidence, _ = prepare(THREAT, [file])
        finding = dict(FINDING, file="new.go", side="base", line=7)
        self.assertEqual(validate_findings({"findings": [finding]}, evidence, THREAT), [finding])
        body = render("example/repo", HEAD, BASE, "a/model", [finding], evidence, [])
        self.assertIn(f"/blob/{BASE}/old.go#L7", body)

    def test_deleted_line_links_use_diff_merge_base_not_current_target(self):
        _, evidence, _ = prepare(THREAT, FILES)
        finding = dict(FINDING, side="base")
        merge_base = "d" * 40
        body = render("example/repo", HEAD, BASE, "a/model", [finding], evidence, [], diff_base=merge_base)
        self.assertIn(f"/blob/{merge_base}/coordinator/auth.go#L4", body)
        self.assertNotIn(f"/blob/{BASE}/", body)

    def test_truncation_limits_evidence_and_is_explicit(self):
        files = copy.deepcopy(FILES)
        files[0]["patch"] = "@@ -1,0 +1,9999 @@\n" + "+x\n" * 9999
        files[0]["additions"] = 9999
        files[0]["deletions"] = 0
        text, evidence, limits = prepare(THREAT, files)
        self.assertLess(len(json.loads(text)["files"][0]["patch"]), 12001)
        self.assertEqual(limits, [files[0]["filename"]])
        self.assertNotIn(9999, evidence[files[0]["filename"]]["lines"]["head"])

    def test_missing_patch_is_not_treated_as_clean(self):
        with self.assertRaises(ReviewUnavailable):
            prepare(THREAT, [dict(FILES[0], patch="")])
        text, _, limits = prepare(THREAT, FILES + [dict(FILES[0], filename="binary.bin", patch="")])
        self.assertIn("binary.bin", limits)
        self.assertIn("binary.bin", text)

    def test_threat_model_limit_fails_before_model_call(self):
        with self.assertRaises(ReviewUnavailable):
            prepare("x" * 220001, FILES)

    def test_invalid_findings_rejected(self):
        _, evidence, _ = prepare(THREAT, FILES)
        mutations = [{"line": 99}, {"file": "unseen.go"}, {"line": True}, {"side": "other"},
                     {"severity": "critical"}, {"threat_ids": ["T-999"]}, {"title": ""},
                     {"detail": "x" * 1601}]
        for mutation in mutations:
            with self.subTest(mutation=mutation), self.assertRaises(ReviewUnavailable):
                validate_findings({"findings": [dict(FINDING, **mutation)]}, evidence, THREAT)

    def test_request_is_bounded_structured_and_key_is_not_prompt_data(self):
        calls = []
        def transport(url, key, body):
            calls.append((url, key, body))
            return completion([FINDING])
        findings, _, _ = review(THREAT, FILES, "private-test-key", "chosen/model", transport)
        url, key, body = calls[0]
        self.assertEqual(url, "https://openrouter.ai/api/v1/chat/completions")
        self.assertEqual(key, "private-test-key")
        self.assertNotIn(key, json.dumps(body))
        self.assertEqual(body["model"], "chosen/model")
        self.assertEqual(body["max_tokens"], 4096)
        self.assertTrue(body["provider"]["require_parameters"])
        self.assertTrue(body["response_format"]["json_schema"]["strict"])
        self.assertEqual(findings, [FINDING])

    def test_incomplete_or_invalid_model_response_not_clean(self):
        responses = [completion([], "length"), {}, {"choices": []},
                     {"choices": [{"finish_reason": "stop", "message": {"content": "not JSON"}}]}]
        for response in responses:
            with self.subTest(response=response), self.assertRaises(ReviewUnavailable):
                review(THREAT, FILES, "key", transport=lambda *args: response)

    def test_render_neutralizes_mentions_markdown_and_html(self):
        _, evidence, _ = prepare(THREAT, FILES)
        finding = dict(FINDING, title="@everyone <img src=x> [link](https://evil.invalid)")
        body = render("example/repo", HEAD, BASE, "a/model", [finding], evidence, [])
        self.assertNotIn("@everyone", body)
        self.assertNotIn("<img", body)
        self.assertNotIn("[link]", body)
        self.assertIn(f"/blob/{HEAD}/coordinator/auth.go#L4", body)


class FakeGitHub:
    def __init__(self, stale=False):
        self.stale, self.reads = stale, 0

    def pull(self):
        self.reads += 1
        return {"state": "open", "head": {"sha": "c" * 40 if self.stale and self.reads > 1 else HEAD},
                "base": {"sha": BASE}, "changed_files": 1}

    def comparison_base(self, base, head):
        return BASE

    def files(self, count):
        return FILES


class FakeAdvisories:
    def __init__(self):
        self.drafts = []

    def create(self, number, head, body):
        self.drafts.append((number, head, body))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/threat-model.yaml").write_text(THREAT)
        self.env = {"GH_TOKEN": "github-test-token", "OPENROUTER_API_KEY": "private-test-key",
                    "THREAT_REVIEW_ADVISORY_TOKEN": "advisory-test-token"}
        self.advisories = FakeAdvisories()

    def reviewer(self, findings):
        def call(threat, files, key, model):
            self.assertEqual(threat, THREAT)
            _, evidence, limits = prepare(threat, files)
            return findings, evidence, limits
        return call

    def execute(self, findings, github=None, env=None, reviewer=None):
        return run(EVENT, self.root, self.env if env is None else env,
                   github or FakeGitHub(), reviewer or self.reviewer(findings), self.advisories)

    def test_findings_create_private_revision_snapshot(self):
        self.assertEqual(self.execute([FINDING]), COMPLETED)
        self.assertEqual(len(self.advisories.drafts), 1)
        number, head, body = self.advisories.drafts[0]
        self.assertEqual((number, head), (12, HEAD))
        self.assertIn("Missing authorization", body)
        self.assertIn("historical snapshot", body)
        self.assertIn("never requests changes", body)

    def test_clean_and_findings_have_identical_public_output(self):
        clean = self.execute([])
        self.assertEqual(self.advisories.drafts, [])
        self.assertEqual(clean, self.execute([FINDING]))

    def test_missing_credentials_skip_model_and_private_delivery(self):
        for missing in ("OPENROUTER_API_KEY", "THREAT_REVIEW_ADVISORY_TOKEN"):
            env = dict(self.env)
            del env[missing]
            result = self.execute([], env=env, reviewer=lambda *args: self.fail("no model call"))
            self.assertEqual(result, UNAVAILABLE)
            self.assertEqual(self.advisories.drafts, [])

    def test_model_errors_cannot_leak_through_public_status(self):
        for error in (ReviewUnavailable, RuntimeError):
            def fail(*args):
                raise error("PRIVATE FINDING private-test-key GHSA-abcd-abcd-abcd")
            self.assertEqual(self.execute([], reviewer=fail), UNAVAILABLE)
        self.assertEqual(self.advisories.drafts, [])

    def test_delivery_error_never_falls_back_to_public_output(self):
        def fail(*args):
            raise ReviewUnavailable("PRIVATE FINDING advisory-test-token")
        self.advisories.create = fail
        self.assertEqual(self.execute([FINDING]), UNAVAILABLE)

    def test_stale_head_does_not_create_advisory(self):
        self.assertEqual(self.execute([FINDING], github=FakeGitHub(stale=True)), SKIPPED)
        self.assertEqual(self.advisories.drafts, [])

    def test_empty_diff_skips_model_and_creates_nothing(self):
        github = FakeGitHub()
        github.files = lambda count: []
        self.assertEqual(self.execute([], github=github,
                         reviewer=lambda *args: self.fail("no model call")), COMPLETED)
        self.assertEqual(self.advisories.drafts, [])

    def test_fork_head_remains_data(self):
        event = copy.deepcopy(EVENT)
        event["pull_request"]["head"]["repo"] = {"full_name": "attacker/fork"}
        self.assertEqual(run(event, self.root, self.env, FakeGitHub(),
                             self.reviewer([FINDING]), self.advisories), COMPLETED)

    def test_invalid_event_never_reaches_private_destination(self):
        event = copy.deepcopy(EVENT)
        event["repository"]["full_name"] = "example/repo/issues/1"
        self.assertEqual(run(event, self.root, self.env, FakeGitHub(),
                             self.reviewer([FINDING]), self.advisories), UNAVAILABLE)
        self.assertEqual(self.advisories.drafts, [])

    def test_public_summary_accepts_only_fixed_status_messages(self):
        summary = self.root / "summary.md"
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            summarize("PRIVATE FINDING GHSA-abcd-abcd-abcd", {"GITHUB_STEP_SUMMARY": str(summary)})
        self.assertNotIn("PRIVATE", output.getvalue() + summary.read_text())
        self.assertNotIn("GHSA", output.getvalue() + summary.read_text())
        self.assertIn(UNAVAILABLE, summary.read_text())

    def test_entrypoint_failure_exits_zero_and_summarizes(self):
        event = self.root / "event.json"
        event.write_text("invalid")
        summary = self.root / "summary.md"
        env = dict(os.environ, GITHUB_EVENT_PATH=str(event), GITHUB_STEP_SUMMARY=str(summary),
                   PYTHONDONTWRITEBYTECODE="1")
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("threat-model-review.py"))],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0)
        self.assertIn("non-blocking", summary.read_text())


class TransportTests(unittest.TestCase):
    def test_http_errors_are_redacted(self):
        with patch("threat_review.client.build_opener") as opener:
            opener.return_value.open.side_effect = HTTPError("https://example.invalid", 401, "private-key", {}, None)
            with self.assertRaisesRegex(ReviewUnavailable, "^API returned HTTP 401$"):
                request_json("https://openrouter.ai/api/v1/chat/completions", "secret", {})

    def test_credentials_never_follow_redirects(self):
        self.assertIsNone(NoRedirects().redirect_request(None, None, 302, "", {}, "https://elsewhere.invalid"))

    def test_private_sink_only_creates_drafts_and_never_publishes_or_updates(self):
        calls = []
        def transport(*args):
            calls.append(args)
            return {"state": "draft", "ghsa_id": "GHSA-private"}
        sink = PrivateAdvisories("example/repo", "advisory-key", transport)
        sink.create(12, HEAD, "PRIVATE FINDING")
        url, token, payload, method = calls[0]
        self.assertEqual(url, "https://api.github.com/repos/example/repo/security-advisories")
        self.assertEqual(token, "advisory-key")
        self.assertEqual(method, "POST")
        self.assertNotIn("state", payload)
        self.assertNotIn("cve_id", payload)
        self.assertNotIn("credits", payload)
        self.assertEqual(payload["description"], "PRIVATE FINDING")
        self.assertEqual(payload["vulnerabilities"][0]["package"]["ecosystem"], "other")

    def test_private_sink_requires_draft_confirmation(self):
        for response in ({}, {"state": "published"}, None):
            sink = PrivateAdvisories("example/repo", "token", lambda *args: response)
            with self.assertRaises(ReviewUnavailable):
                sink.create(12, HEAD, "PRIVATE FINDING")

    def test_comparison_base_must_be_an_immutable_sha(self):
        github = GitHub("example/repo", 12, "token", lambda *args: {"merge_base_commit": {"sha": "main"}})
        with self.assertRaises(ReviewUnavailable):
            github.comparison_base(BASE, HEAD)

    def test_large_or_inconsistent_file_list_fails_closed(self):
        github = GitHub("example/repo", 12, "token", lambda *args: [])
        for count in (501, 1):
            with self.assertRaises(ReviewUnavailable):
                github.files(count)


class WorkflowBoundaryTests(unittest.TestCase):
    def test_secret_bearing_workflow_uses_only_trusted_base_code(self):
        source = (Path(__file__).resolve().parents[1] / "workflows/threat-model-review.yml").read_text()
        self.assertIn("pull_request_target:", source)
        self.assertNotIn("pull_request:\n", source)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", source)
        self.assertNotIn("head.sha", source)
        self.assertNotIn("head.ref", source)
        self.assertIn("persist-credentials: false", source)
        self.assertIn("continue-on-error: true", source)
        self.assertIn("timeout-minutes: 10", source)
        self.assertIn("pull-requests: read", source)
        self.assertNotIn("pull-requests: write", source)
        self.assertIn("secrets.THREAT_REVIEW_ADVISORY_TOKEN", source)
        self.assertNotIn("upload-artifact", source)
        self.assertNotIn("upload-sarif", source)
        self.assertNotIn("checks: write", source)
        self.assertNotIn("contents: write", source)
        self.assertIn("run: python3 .github/scripts/threat-model-review.py", source)
        self.assertNotIn("pip install", source)
        self.assertNotIn("npm", source)


class LocalHTTPIntegrationTests(unittest.TestCase):
    def test_review_and_private_draft_round_trip_with_real_http(self):
        calls = []
        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_GET(self):
                self.respond(None)

            def do_POST(self):
                self.respond(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))

            def respond(self, payload):
                calls.append((self.command, self.path, payload, self.headers.get("Authorization")))
                if self.path == "/repos/example/repo/pulls/12":
                    response = FakeGitHub().pull()
                elif "/compare/" in self.path:
                    response = {"merge_base_commit": {"sha": BASE}}
                elif "/files?" in self.path:
                    response = FILES
                elif self.path == "/api/v1/chat/completions":
                    response = completion([FINDING])
                elif self.path == "/repos/example/repo/security-advisories":
                    response = {"state": "draft", "ghsa_id": "GHSA-private"}
                else:
                    self.send_error(404)
                    return
                data = json.dumps(response).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            def transport(url, key, payload=None, method=None):
                parsed = urlsplit(url)
                local = f"http://127.0.0.1:{server.server_port}{parsed.path}"
                if parsed.query:
                    local += "?" + parsed.query
                return request_json(local, key, payload, method)
            github = GitHub("example/repo", 12, "github-test-token", transport)
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "docs").mkdir()
                (root / "docs/threat-model.yaml").write_text(THREAT)
                env = {"OPENROUTER_API_KEY": "openrouter-test-key",
                       "THREAT_REVIEW_ADVISORY_TOKEN": "advisory-test-token"}
                sink = PrivateAdvisories("example/repo", "advisory-test-token", transport)
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    outcome = run(EVENT, root, env, github,
                                  lambda *args: review(*args, transport=transport), sink)
                    summarize(outcome, {"GITHUB_STEP_SUMMARY": str(root / "summary.md")})
                public_output = output.getvalue() + (root / "summary.md").read_text()
            self.assertEqual(outcome, COMPLETED)
            model_call = next(c for c in calls if c[1] == "/api/v1/chat/completions")
            self.assertEqual(model_call[3], "Bearer openrouter-test-key")
            self.assertNotIn("github-test-token", json.dumps(model_call[2]))
            self.assertNotIn("advisory-test-token", json.dumps(model_call[2]))
            reports = [c for c in calls if c[0] == "POST" and c[1].endswith("/security-advisories")]
            self.assertEqual(len(reports), 1)
            self.assertEqual(reports[0][3], "Bearer advisory-test-token")
            self.assertIn("Missing authorization", reports[0][2]["description"])
            self.assertFalse(any("/comments" in c[1] or c[0] == "PATCH" for c in calls))
            for secret in ("Missing authorization", "GHSA-private", "coordinator/auth.go",
                           "github-test-token", "openrouter-test-key", "advisory-test-token"):
                self.assertNotIn(secret, public_output)
        finally:
            server.shutdown()
            worker.join()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
