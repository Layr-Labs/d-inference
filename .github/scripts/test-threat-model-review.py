#!/usr/bin/env python3
"""Cloud-free regressions for advisory outcomes and trusted-data boundaries."""
import base64
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

from threat_review.client import GitHub, NoRedirects, ReviewUnavailable, ScanTimeout, SourceBudgetExceeded, request_json
from threat_review.report import MARKER, LEGACY_MARKER, render
from threat_review.review import prepare, review, validate_findings
from threat_review.runner import run

HEAD, BASE = "a" * 40, "b" * 40
THREAT = "threats:\n  - id: T-001\n    affected_files: [coordinator/auth.go]\n"
FILES = [{"filename": "coordinator/auth.go", "status": "modified", "additions": 1,
          "deletions": 1, "patch": "@@ -4,2 +4,2 @@\n-checkAuth()\n+allowAll()\n next()"}]
FINDING = {"severity": "high", "title": "Missing authorization", "detail": "An unauthenticated request reaches the operation; retain the authorization check.",
           "file": "coordinator/auth.go", "line": 4, "side": "head", "threat_ids": ["T-001"]}
EVENT = {"repository": {"full_name": "example/repo"}, "pull_request": {
    "number": 12, "head": {"sha": HEAD}, "base": {"sha": BASE, "ref": "master"}, "draft": False}}


def completion(findings, reason="stop", body=None):
    sent = json.loads(body["messages"][1]["content"]) if body else {"units": []}
    result = {"findings": findings, "covered_units": [unit["id"] for unit in sent["units"]],
              "analysis": "Review authorization flow and T-001 across coordinator/auth.go."}
    return {"choices": [{"finish_reason": reason, "message": {"content": json.dumps(result)}}]}


def source_response(path):
    if "/git/commits/" in path:
        return {"tree": {"sha": ("1" if path.endswith(BASE) else "2") * 40}}
    if "/git/trees/" in path:
        sha = path.rsplit("/", 1)[-1]
        if sha[0] in "12":
            return {"tree": [{"path": "coordinator", "type": "tree", "sha": ("3" if sha[0] == "1" else "4") * 40}]}
        return {"tree": [{"path": "auth.go", "type": "blob", "mode": "100644", "sha": ("5" if sha[0] == "3" else "6") * 40}]}
    if "/git/blobs/" in path:
        raw = b"1\n2\n3\n" + (b"checkAuth()" if path.endswith("5" * 40) else b"allowAll()") + b"\nnext()\n"
        return {"encoding": "base64", "content": base64.b64encode(raw).decode(), "size": len(raw)}
    raise AssertionError(path)



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

    def test_large_patch_is_preserved_in_full(self):
        files = copy.deepcopy(FILES)
        files[0]["patch"] = "@@ -1,0 +1,9999 @@\n" + "+x\n" * 9999
        files[0]["additions"], files[0]["deletions"] = 9999, 0
        text, evidence, limits = prepare(THREAT, files)
        self.assertEqual(json.loads(text)["files"][0]["patch"], files[0]["patch"])
        self.assertEqual(limits, [])
        self.assertIn(9999, evidence[files[0]["filename"]]["lines"]["head"])

    def test_missing_patch_is_not_treated_as_clean(self):
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

    def test_all_canonical_id_families_survive_full_scan(self):
        threat_model = """adversaries:
  - id: ADV-001
assets:
  - id: 'A-001'
trust_boundaries:
  - id: "TB-001" # boundary reference
threats:
  - id: T-001
    security_findings:
      - id: SEC-006
"""
        finding = dict(FINDING, threat_ids=["ADV-001", "A-001", "TB-001", "T-001", "SEC-006"])
        calls = []
        def transport(url, key, body):
            calls.append(body)
            return completion([finding], body=body)
        findings, _, limits = review(threat_model, FILES, "key", transport=transport)
        self.assertEqual(findings, [finding])
        self.assertEqual(limits, [])
        self.assertEqual(len(calls), 2)  # Source pass plus cross-file integration.

    def test_prose_mentions_do_not_define_canonical_ids(self):
        threat_model = THREAT + "    description: Compare T-999 and ADV-999, neither is defined.\n"
        _, evidence, _ = prepare(threat_model, FILES)
        for identifier in ("T-999", "ADV-999", "A-999", "TB-999", "SEC-999"):
            with self.subTest(identifier=identifier), self.assertRaises(ReviewUnavailable):
                validate_findings({"findings": [dict(FINDING, threat_ids=[identifier])]}, evidence, threat_model)

    def test_request_is_bounded_structured_and_key_is_not_prompt_data(self):
        calls = []
        def transport(url, key, body):
            calls.append((url, key, body))
            return completion([FINDING], body=body)
        findings, _, _ = review(THREAT, FILES, "private-test-key", "chosen/model", transport)
        url, key, body = calls[0]
        self.assertEqual(url, "https://openrouter.ai/api/v1/chat/completions")
        self.assertEqual(key, "private-test-key")
        self.assertNotIn(key, json.dumps(body))
        self.assertEqual(body["model"], "chosen/model")
        self.assertEqual(body["max_tokens"], 16384)
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

    def call(self, path):
        return source_response(path)

    def pull(self):
        self.reads += 1
        return {"state": "open", "head": {"sha": "c" * 40 if self.stale and self.reads > 1 else HEAD},
                "base": {"sha": BASE, "ref": "master"}, "changed_files": 1}

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

    def prior_report(self, head=HEAD):
        _, evidence, _ = prepare(THREAT, FILES)
        return {"id": 17, "body": render("example/repo", head, BASE, "prior/model", [FINDING], evidence, [])}

    def test_failed_same_head_retry_retains_findings_and_is_idempotent(self):
        existing = self.prior_report()
        env = {"GH_TOKEN": "github-test-token"}
        github = FakeGitHub(existing)
        run(EVENT, self.root, env, github)
        body = github.posts[0][1]
        self.assertTrue(body.startswith(existing["body"]))
        self.assertIn("Retry incomplete", body)
        self.assertNotIn("superseded", body)
        github = FakeGitHub({"id": 17, "body": body})
        run(EVENT, self.root, env, github)
        self.assertEqual(github.posts[0][1], body)

    def test_source_failure_retains_same_head_findings(self):
        github = FakeGitHub(self.prior_report())
        github.files = lambda count: (_ for _ in ()).throw(ReviewUnavailable("source unavailable"))
        run(EVENT, self.root, self.env, github)
        self.assertIn(FINDING["title"], github.posts[0][1])
        self.assertIn("Retry incomplete", github.posts[0][1])

    def test_partial_retry_preserves_old_and_new_findings(self):
        github = FakeGitHub(self.prior_report())
        env = dict(self.env, THREAT_REVIEW_MODELS="good/model,bad/model")
        def reviewer(threat, files, key, model):
            if model == "bad/model":
                raise ReviewUnavailable("model unavailable")
            return self.reviewer([dict(FINDING, title="Another authorization issue")])(threat, files, key, model)
        run(EVENT, self.root, env, github, reviewer)
        body = github.posts[0][1]
        self.assertIn(FINDING["title"], body)
        self.assertIn("Another authorization issue", body)
        self.assertIn("Retry incomplete", body)

    def test_incomplete_source_retry_preserves_findings(self):
        github = FakeGitHub(self.prior_report())
        github.call = lambda path: ({"encoding": "base64", "content": "AA==", "size": 1}
                                    if "/blobs/" in path else source_response(path))
        run(EVENT, self.root, self.env, github, self.reviewer([]))
        self.assertIn(FINDING["title"], github.posts[0][1])
        self.assertIn("Scan incomplete", github.posts[0][1])

    def test_new_head_failure_supersedes_old_findings(self):
        github = FakeGitHub(self.prior_report("c" * 40))
        run(EVENT, self.root, {"GH_TOKEN": "github-test-token"}, github)
        self.assertNotIn(FINDING["title"], github.posts[0][1])
        self.assertIn("superseded", github.posts[0][1])

    def test_complete_same_head_retry_can_clear_findings(self):
        github = FakeGitHub(self.prior_report())
        run(EVENT, self.root, self.env, github, self.reviewer([]))
        self.assertNotIn(FINDING["title"], github.posts[0][1])
        self.assertIn("No actionable findings", github.posts[0][1])

    def test_retry_capacity_preserves_comment_and_reports_partial_findings_in_summary(self):
        existing = self.prior_report()
        existing["body"] += "\n" + "x" * (59900 - len(existing["body"]))
        github = FakeGitHub(existing)
        def reviewer(threat, files, key, model):
            if model == "bad/model":
                raise ReviewUnavailable("model unavailable")
            return self.reviewer([dict(FINDING, title="New partial finding")])(threat, files, key, model)
        result = run(EVENT, self.root, dict(self.env, THREAT_REVIEW_MODELS="good/model,bad/model"), github, reviewer)
        self.assertEqual(github.posts, [])
        self.assertIn("earlier same-head findings remain", result)
        self.assertIn("New partial finding", result)

    def test_legacy_bot_comment_is_migrated_in_place(self):
        for findings in ([], [FINDING]):
            with self.subTest(findings=bool(findings)):
                writes = []
                def transport(url, token, payload, method):
                    if method:
                        writes.append((url, method, payload))
                        return {}
                    if "/git/" in url:
                        return source_response(url)
                    if "/comments?" in url:
                        return [
                            {"id": 5, "user": {"login": "attacker"}, "body": LEGACY_MARKER},
                            {"id": 7, "user": {"login": "github-actions[bot]"},
                             "body": LEGACY_MARKER + "\nOld findings"}]
                    if "/compare/" in url:
                        return {"merge_base_commit": {"sha": BASE}}
                    if "/files?" in url:
                        return FILES
                    return FakeGitHub().pull()
                github = GitHub("example/repo", 12, "token", transport)
                run(EVENT, self.root, self.env, github, self.reviewer(findings))
                self.assertEqual(len(writes), 1)
                url, method, payload = writes[0]
                self.assertTrue(url.endswith("/issues/comments/7"))
                self.assertEqual(method, "PATCH")
                self.assertTrue(payload["body"].startswith(MARKER))
                self.assertIn("Missing authorization" if findings else "No actionable findings", payload["body"])

    def test_missing_key_skips_model_and_posts_incomplete_comment(self):
        github = FakeGitHub()
        result = run(EVENT, self.root, {"GH_TOKEN": "token"}, github,
                     lambda *args: self.fail("model must not be called"))
        self.assertIn("Review unavailable", result)
        self.assertIn("Review not completed", github.posts[0][1])

    def test_aggregate_source_limit_posts_incomplete_without_model_call(self):
        github = FakeGitHub()
        with patch("threat_review.source.MAX_SOURCE_BYTES", 0):
            result = run(EVENT, self.root, self.env, github,
                         lambda *args: self.fail("an over-budget collection must not call the model"))
        self.assertIn("aggregate source", result)
        self.assertIn("split the PR", github.posts[0][1])
        self.assertNotIn("No actionable findings", github.posts[0][1])

    def test_outage_marks_old_comment_unreviewed_not_clean(self):
        github = FakeGitHub({"id": 17})
        def unavailable(*args):
            raise ReviewUnavailable("API returned HTTP 429")
        result = run(EVENT, self.root, self.env, github, unavailable)
        self.assertIn("non-blocking", result)
        self.assertIn("not confirmed resolved", github.posts[0][1])

    def test_review_errors_do_not_leak_credentials(self):
        for error_type in (ReviewUnavailable, RuntimeError):
            with self.subTest(error_type=error_type):
                github = FakeGitHub({"id": 17})
                def fail(*args):
                    raise error_type("private-test-key")
                result = run(EVENT, self.root, self.env, github, fail)
                self.assertNotIn("private-test-key", result + github.posts[0][1])

    def test_incomplete_source_never_posts_clean(self):
        github = FakeGitHub()
        def call(path):
            if "/blobs/" in path:
                return {"encoding": "base64", "content": "AA==", "size": 1}
            return source_response(path)
        github.call = call
        result = run(EVENT, self.root, self.env, github, self.reviewer([]))
        self.assertIn("Scan incomplete", result)
        self.assertIn("Scan incomplete", github.posts[0][1])
        self.assertNotIn("No actionable findings", github.posts[0][1])

    def test_stale_head_does_not_publish(self):
        github = FakeGitHub(stale=True)
        result = run(EVENT, self.root, self.env, github, self.reviewer([FINDING]))
        self.assertIn("no stale comment", result)
        self.assertEqual(github.posts, [])

    def test_deadline_during_final_read_preserves_completed_and_prior_findings(self):
        github = FakeGitHub(self.prior_report())
        pull = github.pull
        def timed_pull():
            current = pull()
            if github.reads == 3:
                raise ScanTimeout("deadline")
            return current
        github.pull = timed_pull
        result = run(EVENT, self.root, self.env, github,
                     self.reviewer([dict(FINDING, title="Completed current finding")]))
        self.assertIn("runtime limit reached during final", result)
        self.assertEqual(len(github.posts), 1)
        self.assertIn(FINDING["title"], github.posts[0][1])
        self.assertIn("Completed current finding", github.posts[0][1])

    def test_deadline_after_comment_creation_reuses_the_created_comment(self):
        comments, writes = [], []
        def transport(url, token, payload, method):
            if method == "POST":
                writes.append(method)
                comments.append({"id": 44, "user": {"login": "github-actions[bot]"}, "body": payload["body"]})
                raise ScanTimeout("response interrupted after creation")
            if method == "PATCH":
                writes.append(method)
                self.assertTrue(url.endswith("/issues/comments/44"))
                comments[0]["body"] = payload["body"]
                return comments[0]
            if "/comments?" in url:
                return comments
            if "/git/" in url:
                return source_response(url)
            if "/compare/" in url:
                return {"merge_base_commit": {"sha": BASE}}
            if "/files?" in url:
                return FILES
            return FakeGitHub().pull()
        github = GitHub("example/repo", 12, "key", transport)
        result = run(EVENT, self.root, self.env, github, self.reviewer([FINDING]))
        self.assertIn("runtime limit reached during final", result)
        self.assertEqual(writes, ["POST", "PATCH"])
        self.assertEqual(len(comments), 1)
        self.assertIn(FINDING["title"], comments[0]["body"])
        self.assertIn("Retry incomplete", comments[0]["body"])

    def test_base_tip_advance_before_or_during_scan_keeps_review(self):
        for advance_on_read in (1, 2, 3):
            with self.subTest(advance_on_read=advance_on_read):
                github = FakeGitHub()
                pull = github.pull
                def advancing():
                    current = pull()
                    if github.reads >= advance_on_read:
                        current["base"]["sha"] = "d" * 40
                    return current
                github.pull = advancing
                result = run(EVENT, self.root, self.env, github, self.reviewer([FINDING]))
                self.assertIn("Full PR scan completed", result)
                self.assertEqual(len(github.posts), 1)
                self.assertIn(FINDING["title"], github.posts[0][1])
                self.assertIn(f"against base `{BASE[:12]}`", github.posts[0][1])

    def test_retarget_or_close_before_or_during_scan_suppresses_review(self):
        for change_on_read in (1, 2, 3):
            for change in ("retarget", "close"):
                with self.subTest(change_on_read=change_on_read, change=change):
                    github = FakeGitHub()
                    pull = github.pull
                    def changed():
                        current = pull()
                        if github.reads >= change_on_read:
                            if change == "retarget":
                                current["base"]["ref"] = "release"
                            else:
                                current["state"] = "closed"
                        return current
                    github.pull = changed
                    result = run(EVENT, self.root, self.env, github, self.reviewer([FINDING]))
                    self.assertIn("Skipped", result)
                    self.assertEqual(github.posts, [])

    def test_base_advance_changing_diff_or_unverifiable_is_incomplete(self):
        for unavailable in (False, True):
            with self.subTest(unavailable=unavailable):
                github = FakeGitHub(self.prior_report())
                pull = github.pull
                def advancing():
                    current = pull()
                    current["base"]["sha"] = "d" * 40
                    return current
                def comparison(base, head):
                    if base == BASE:
                        return BASE
                    if unavailable:
                        raise ReviewUnavailable("private-test-key")
                    return "e" * 40
                github.pull, github.comparison_base = advancing, comparison
                result = run(EVENT, self.root, self.env, github, self.reviewer([]))
                self.assertIn("Scan incomplete", result)
                self.assertIn(FINDING["title"], github.posts[0][1])
                self.assertNotIn("No actionable findings", github.posts[0][1])
                self.assertNotIn("private-test-key", result + github.posts[0][1])

    def test_changed_merge_base_before_or_during_collection_never_calls_models(self):
        for change_on_read in (1, 2):
            with self.subTest(change_on_read=change_on_read):
                github = FakeGitHub()
                pull = github.pull
                def advancing():
                    current = pull()
                    if github.reads >= change_on_read:
                        current["base"]["sha"] = "d" * 40
                    return current
                github.pull = advancing
                github.comparison_base = lambda base, head: BASE if base == BASE else "e" * 40
                if change_on_read == 1:
                    github.files = lambda count: self.fail("known mismatched diffs must not be enumerated")
                result = run(EVENT, self.root, self.env, github,
                             lambda *args: self.fail("mismatched snapshots must not reach models"))
                self.assertIn("before scanning", result)
                self.assertIn("Scan incomplete", github.posts[0][1])

    def test_merge_base_change_after_scan_discards_new_but_retains_prior_findings(self):
        for partial in (False, True):
            for unavailable in (False, True):
                with self.subTest(partial=partial, unavailable=unavailable):
                    github = FakeGitHub(self.prior_report())
                    pull = github.pull
                    def advancing():
                        current = pull()
                        if github.reads >= 3:
                            current["base"]["sha"] = "d" * 40
                        return current
                    def comparison(base, head):
                        if base == BASE:
                            return BASE
                        if unavailable:
                            raise ReviewUnavailable("private-test-key")
                        return "e" * 40
                    def reviewer(threat, files, key, model):
                        if partial and model == "bad/model":
                            raise ReviewUnavailable("unavailable")
                        return self.reviewer([dict(FINDING, title="Untrusted mixed snapshot")])(threat, files, key, model)
                    github.pull, github.comparison_base = advancing, comparison
                    env = dict(self.env, THREAT_REVIEW_MODELS="good/model,bad/model")
                    result = run(EVENT, self.root, env, github, reviewer)
                    self.assertIn("new findings were discarded", result)
                    body = github.posts[0][1]
                    self.assertIn(FINDING["title"], body)
                    self.assertNotIn("Untrusted mixed snapshot", body)
                    self.assertNotIn("private-test-key", result + body)

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

    def test_canonical_comment_consolidates_legacy_and_versioned_duplicates(self):
        comments = [{"id": 1, "user": {"login": "github-actions[bot]"}, "body": LEGACY_MARKER + " old"}]
        comments += [{"id": id, "user": {"login": "attacker"}, "body": MARKER if id == 2 else "note"}
                     for id in range(2, 101)]
        comments += [{"id": id, "user": {"login": "github-actions[bot]"}, "body": MARKER + f" report {id}"}
                     for id in (101, 102)]
        writes = []
        def transport(url, token, payload, method):
            if method == "PATCH":
                id = int(url.rsplit("/", 1)[-1])
                writes.append(id)
                comment = next(comment for comment in comments if comment["id"] == id)
                comment["body"] = payload["body"]
                return comment
            page = int(url.rsplit("=", 1)[-1])
            return comments[(page - 1) * 100:page * 100]
        github = GitHub("example/repo", 12, "key", transport)
        existing = github.existing_comment((MARKER, LEGACY_MARKER))
        self.assertEqual(existing["id"], 102)
        github.publish(existing, MARKER + " current")
        self.assertEqual(writes, [102, 1, 101])
        for id in (1, 101):
            body = next(comment["body"] for comment in comments if comment["id"] == id)
            self.assertIn("#issuecomment-102", body)
            self.assertFalse(body.startswith((MARKER, LEGACY_MARKER)))
        self.assertEqual(comments[1]["body"], MARKER)  # Human spoof is untouched.
        existing = github.existing_comment((MARKER, LEGACY_MARKER))
        self.assertEqual(existing["duplicate_ids"], [])
        github.publish(existing, MARKER + " refreshed")
        self.assertEqual(writes, [102, 1, 101, 102])

    def test_comparison_base_must_be_an_immutable_sha(self):
        github = GitHub("example/repo", 12, "token", lambda *args: {"merge_base_commit": {"sha": "main"}})
        with self.assertRaises(ReviewUnavailable):
            github.comparison_base(BASE, HEAD)

    def test_large_or_inconsistent_file_list_fails_closed(self):
        github = GitHub("example/repo", 12, "token", lambda *args: [])
        for count in (3001, 1):
            with self.assertRaises(ReviewUnavailable):
                github.files(count)

    def test_file_list_patch_budget_stops_pagination(self):
        calls = []
        first = [{"filename": str(i), "patch": "+content"} for i in range(100)]
        def transport(url, *args):
            calls.append(url)
            return first if len(calls) == 1 else [{"filename": "extra", "patch": "+more"}]
        github = GitHub("example/repo", 12, "key", transport)
        limit = len(json.dumps(first).encode("utf-8"))
        with patch("threat_review.client.MAX_FILE_LIST_BYTES", limit):
            with self.assertRaises(SourceBudgetExceeded):
                github.files(101)
        self.assertEqual(len(calls), 2)


class WorkflowBoundaryTests(unittest.TestCase):
    def test_retarget_events_are_gated_before_review_concurrency(self):
        source = (Path(__file__).resolve().parents[1] / "workflows/threat-model-review.yml").read_text()
        self.assertRegex(source, r"types: \[[^\n\]]*\bedited\b")
        self.assertIn("github.event.action != 'edited' || github.event.changes.base.ref.from != ''", source)
        self.assertNotIn("\nconcurrency:", source)
        self.assertIn("\n    concurrency:\n", source)

    def test_secret_bearing_workflow_uses_only_trusted_base_code(self):
        source = (Path(__file__).resolve().parents[1] / "workflows/threat-model-review.yml").read_text()
        self.assertIn("pull_request_target:", source)
        self.assertNotIn("pull_request:\n", source)
        self.assertIn("ref: ${{ github.event.pull_request.base.sha }}", source)
        self.assertNotIn("head.sha", source)
        self.assertNotIn("head.ref", source)
        self.assertIn("persist-credentials: false", source)
        self.assertIn("continue-on-error: true", source)
        self.assertIn("timeout-minutes: 60", source)
        self.assertIn("pull-requests: write", source)
        self.assertNotIn("THREAT_REVIEW_ADVISORY_TOKEN", source)
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
                elif "/git/" in self.path:
                    response = source_response(self.path)
                elif "/compare/" in self.path:
                    response = {"merge_base_commit": {"sha": BASE}}
                elif "/files?" in self.path:
                    response = FILES
                elif "/comments?" in self.path:
                    response = []
                elif self.path == "/api/v1/chat/completions":
                    response = completion([FINDING], body=payload)
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
