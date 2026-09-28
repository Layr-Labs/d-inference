#!/usr/bin/env python3
"""Cloud-free regressions for advisory outcomes and trusted-data boundaries."""
import copy
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

from threat_review.client import GitHub, NoRedirects, ReviewUnavailable, request_json
from threat_review.report import MARKER, render
from threat_review.review import prepare, review, validate_findings
from threat_review.runner import run

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
    def __init__(self, existing=None, stale=False):
        self.existing, self.stale, self.reads, self.posts = existing, stale, 0, []

    def pull(self):
        self.reads += 1
        return {"state": "open", "head": {"sha": "c" * 40 if self.stale and self.reads > 1 else HEAD},
                "base": {"sha": BASE}, "changed_files": 1}

    def comparison_base(self, base, head):
        return BASE

    def files(self, count):
        return FILES

    def existing_comment(self, marker):
        return self.existing

    def publish(self, existing, body):
        self.posts.append((existing, body))


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "docs").mkdir()
        (self.root / "docs/threat-model.yaml").write_text(THREAT)
        self.env = {"GH_TOKEN": "github-test-token", "OPENROUTER_API_KEY": "private-test-key"}

    def reviewer(self, findings):
        def call(threat, files, key, model):
            self.assertEqual(threat, THREAT)
            _, evidence, limits = prepare(threat, files)
            return findings, evidence, limits
        return call

    def test_findings_post_one_advisory_comment(self):
        github = FakeGitHub()
        result = run(EVENT, self.root, self.env, github, self.reviewer([FINDING]))
        self.assertIn("1 finding", result)
        self.assertEqual(len(github.posts), 1)
        self.assertTrue(github.posts[0][1].startswith(MARKER))
        self.assertIn("never requests changes", github.posts[0][1])

    def test_clean_run_is_quiet(self):
        github = FakeGitHub()
        result = run(EVENT, self.root, self.env, github, self.reviewer([]))
        self.assertIn("0 finding", result)
        self.assertEqual(github.posts, [])

    def test_old_findings_updated_on_clean_run(self):
        existing = {"id": 17}
        github = FakeGitHub(existing)
        run(EVENT, self.root, self.env, github, self.reviewer([]))
        self.assertEqual(github.posts[0][0], existing)
        self.assertIn("No actionable findings", github.posts[0][1])

    def test_missing_key_skips_model_and_does_not_post_new_comment(self):
        github = FakeGitHub()
        result = run(EVENT, self.root, {"GH_TOKEN": "token"}, github,
                     lambda *args: self.fail("model must not be called"))
        self.assertIn("not configured", result)
        self.assertEqual(github.posts, [])

    def test_outage_marks_old_comment_unreviewed_not_clean(self):
        github = FakeGitHub({"id": 17})
        def unavailable(*args):
            raise ReviewUnavailable("API returned HTTP 429")
        result = run(EVENT, self.root, self.env, github, unavailable)
        self.assertIn("non-blocking", result)
        self.assertIn("not confirmed resolved", github.posts[0][1])

    def test_unexpected_exception_does_not_leak_credentials(self):
        github = FakeGitHub({"id": 17})
        def fail(*args):
            raise RuntimeError("private-test-key")
        result = run(EVENT, self.root, self.env, github, fail)
        self.assertNotIn("private-test-key", result + github.posts[0][1])

    def test_stale_head_does_not_publish(self):
        github = FakeGitHub(stale=True)
        result = run(EVENT, self.root, self.env, github, self.reviewer([FINDING]))
        self.assertIn("no stale comment", result)
        self.assertEqual(github.posts, [])

    def test_fork_head_is_data_and_never_a_checkout(self):
        event = copy.deepcopy(EVENT)
        event["pull_request"]["head"]["repo"] = {"full_name": "attacker/fork"}
        github = FakeGitHub()
        run(event, self.root, self.env, github, self.reviewer([FINDING]))
        self.assertEqual(len(github.posts), 1)

    def test_empty_diff_supersedes_old_findings_without_model_call(self):
        github = FakeGitHub({"id": 17})
        github.files = lambda count: []
        run(EVENT, self.root, self.env, github,
            lambda *args: self.fail("empty diff must not call the model"))
        self.assertIn("No actionable findings", github.posts[0][1])

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

    def test_comment_lookup_paginates_and_ignores_spoofed_markers(self):
        def transport(url, *args):
            if url.endswith("&page=1"):
                return [{"user": {"login": "attacker"}, "body": MARKER}] * 100
            return [{"id": 7, "user": {"login": "github-actions[bot]"}, "body": MARKER + "\nold"}]
        github = GitHub("example/repo", 12, "token", transport)
        self.assertEqual(github.existing_comment(MARKER)["id"], 7)

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
        self.assertNotIn("checks: write", source)
        self.assertNotIn("contents: write", source)
        self.assertIn("run: python3 .github/scripts/threat-model-review.py", source)
        self.assertNotIn("pip install", source)
        self.assertNotIn("npm", source)


class LocalHTTPIntegrationTests(unittest.TestCase):
    def test_review_and_comment_round_trip_with_real_http(self):
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
                elif "/comments?" in self.path:
                    response = []
                elif self.path == "/api/v1/chat/completions":
                    response = completion([FINDING])
                elif self.path == "/repos/example/repo/issues/12/comments":
                    response = {"id": 1}
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
                outcome = run(EVENT, root, {"OPENROUTER_API_KEY": "openrouter-test-key"}, github,
                              lambda *args: review(*args, transport=transport))
            self.assertIn("1 finding", outcome)
            model_call = next(c for c in calls if c[1] == "/api/v1/chat/completions")
            self.assertEqual(model_call[3], "Bearer openrouter-test-key")
            self.assertNotIn("github-test-token", json.dumps(model_call[2]))
            comments = [c for c in calls if c[0] == "POST" and c[1].endswith("/comments")]
            self.assertEqual(len(comments), 1)
            self.assertEqual(comments[0][3], "Bearer github-test-token")
            self.assertIn("Missing authorization", comments[0][2]["body"])
        finally:
            server.shutdown()
            worker.join()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
