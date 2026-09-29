#!/usr/bin/env python3
"""Coverage regressions for immutable sources and multi-pass full PR scanning."""
import base64
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fixtures", Path(__file__).with_name("test-threat-model-review.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
from threat_review.client import GitHub, ReviewUnavailable, ScanTimeout, SourceBudgetExceeded
from threat_review.review import prepare, review, validate_findings
from threat_review.report import render
from threat_review.source import Sources, complete_files
from threat_review.scan import units


class SourceTests(unittest.TestCase):
    def test_aggregate_source_budget_stops_before_caching_next_blob(self):
        first_sha, second_sha = "5" * 40, "6" * 40
        size = fixtures.source_response("/git/blobs/" + first_sha)["size"]
        sources = Sources(fixtures.FakeGitHub())
        with patch("threat_review.source.MAX_SOURCE_BYTES", size):
            sources.read(fixtures.BASE, "coordinator/auth.go")
            with self.assertRaises(SourceBudgetExceeded):
                sources.read(fixtures.HEAD, "coordinator/auth.go")
        self.assertIn(first_sha, sources.blobs)
        self.assertNotIn(second_sha, sources.blobs)
        self.assertEqual(sources.source_bytes, size)

    def test_repeated_cached_source_is_charged_for_each_use(self):
        github, calls = fixtures.FakeGitHub(), []
        def call(path):
            calls.append(path)
            return fixtures.source_response(path)
        github.call = call
        sources = Sources(github)
        size = fixtures.source_response("/git/blobs/" + "5" * 40)["size"]
        with patch("threat_review.source.MAX_SOURCE_BYTES", 2 * size):
            for _ in range(2):
                sources.read(fixtures.BASE, "coordinator/auth.go")
            with self.assertRaises(SourceBudgetExceeded):
                sources.read(fixtures.BASE, "coordinator/auth.go")
        self.assertEqual(sources.source_bytes, 2 * size)
        self.assertEqual(len([path for path in calls if "/blobs/" in path]), 1)

    def test_aggregate_tree_budget_stops_before_caching_next_tree(self):
        sources = Sources(fixtures.FakeGitHub())
        root = fixtures.source_response("/git/trees/" + "1" * 40)
        size = len(json.dumps(root).encode("utf-8"))
        with patch("threat_review.source.MAX_TREE_BYTES", size):
            with self.assertRaises(SourceBudgetExceeded):
                sources.read(fixtures.BASE, "coordinator/auth.go")
        self.assertEqual(set(sources.trees), {"1" * 40})
        self.assertEqual(sources.tree_bytes, size)
        self.assertFalse(sources.blobs)

    def test_global_budget_aborts_collection_instead_of_continuing_files(self):
        github, calls = fixtures.FakeGitHub(), []
        def call(path):
            calls.append(path)
            return fixtures.source_response(path)
        github.call = call
        with patch("threat_review.source.MAX_SOURCE_BYTES", 0):
            with self.assertRaises(SourceBudgetExceeded):
                complete_files(github, fixtures.FILES * 10, fixtures.BASE, fixtures.HEAD)
        self.assertEqual(len([path for path in calls if "/blobs/" in path]), 1)

    def test_missing_api_patch_rebuilt_from_complete_immutable_sources(self):
        github = fixtures.FakeGitHub()
        files = complete_files(github, [dict(fixtures.FILES[0], patch="")], fixtures.BASE, fixtures.HEAD)
        self.assertTrue(files[0]["source_complete"])
        self.assertIn("-checkAuth()", files[0]["patch"])
        self.assertIn("+allowAll()", files[0]["patch"])
        self.assertEqual(files[0]["head_text"], "1\n2\n3\nallowAll()\nnext()\n")
        _, evidence, limits = prepare(fixtures.THREAT, files)
        self.assertIn(4, evidence[files[0]["filename"]]["lines"]["head"])
        self.assertFalse(limits)

    def test_binary_or_incomplete_blob_is_explicit_not_clean(self):
        for raw, size in ((b"a\0b", 3), (b"short", 100), (b"\xff", 1)):
            github = fixtures.FakeGitHub()
            def call(path):
                if "/blobs/" in path:
                    return {"encoding": "base64", "content": base64.b64encode(raw).decode(), "size": size}
                return fixtures.source_response(path)
            github.call = call
            files = complete_files(github, fixtures.FILES, fixtures.BASE, fixtures.HEAD)
            self.assertFalse(files[0]["source_complete"])
            self.assertEqual(prepare(fixtures.THREAT, files)[2], ["coordinator/auth.go"])

    def test_lfs_pointers_on_either_side_require_manual_review(self):
        for version in ("https://git-lfs.github.com/spec/v1", "https://hawser.github.com/spec/v1",
                        "http://git-media.io/v/2"):
            for status, blob_sha in (("added", "6" * 40), ("removed", "5" * 40),
                                     ("modified", "5" * 40), ("modified", "6" * 40)):
                with self.subTest(version=version, status=status, blob_sha=blob_sha):
                    raw = f"version {version}\noid sha256:{'a' * 64}\nsize 4096\n".encode()
                    github = fixtures.FakeGitHub()
                    def call(path):
                        if path.endswith("/blobs/" + blob_sha):
                            return {"encoding": "base64", "content": base64.b64encode(raw).decode(), "size": len(raw)}
                        return fixtures.source_response(path)
                    github.call = call
                    files = complete_files(github, [dict(fixtures.FILES[0], status=status)], fixtures.BASE, fixtures.HEAD)
                    self.assertFalse(files[0]["source_complete"])
                    _, evidence, limits = prepare(fixtures.THREAT, files)
                    body = render("example/repo", fixtures.HEAD, fixtures.BASE, "model", [], evidence, limits)
                    self.assertIn("Git LFS", body)
                    self.assertIn("coordinator/auth", body)
                    self.assertNotIn("No actionable findings", body)

    def test_sources_never_follow_symlinks_and_reject_truncated_trees(self):
        github = fixtures.FakeGitHub()
        def call(path):
            result = fixtures.source_response(path)
            if "/trees/" in path and path.endswith("3" * 40):
                result["tree"][0]["mode"] = "120000"
            return result
        github.call = call
        text, mode = Sources(github).read(fixtures.BASE, "coordinator/auth.go")
        self.assertEqual(mode, "120000")
        self.assertIn("checkAuth()", text)
        github.call = lambda path: ({"tree": {"sha": "1" * 40}} if "/commits/" in path else {"tree": [], "truncated": True})
        with self.assertRaises(ReviewUnavailable):
            Sources(github).read(fixtures.BASE, "coordinator/auth.go")

    def test_submodule_is_explicitly_incomplete(self):
        github = fixtures.FakeGitHub()
        def call(path):
            result = fixtures.source_response(path)
            if "/trees/" in path and path.endswith("3" * 40):
                result["tree"][0]["type"] = "commit"
            return result
        github.call = call
        files = complete_files(github, fixtures.FILES, fixtures.BASE, fixtures.HEAD)
        self.assertFalse(files[0]["source_complete"])

    def test_added_deleted_renamed_and_mode_only_sources(self):
        for status in ("added", "removed", "renamed", "modified"):
            with self.subTest(status=status):
                calls = []
                github = fixtures.FakeGitHub()
                def call(path):
                    calls.append(path)
                    return fixtures.source_response(path)
                github.call = call
                file = dict(fixtures.FILES[0], status=status, previous_filename="coordinator/auth.go")
                result = complete_files(github, [file], fixtures.BASE, fixtures.HEAD)[0]
                self.assertTrue(result["source_complete"])
                if status == "added":
                    self.assertEqual(result["base_text"], "")
                    self.assertFalse(any(fixtures.BASE in path for path in calls))
                if status == "removed":
                    self.assertEqual(result["head_text"], "")
                    self.assertFalse(any(fixtures.HEAD in path for path in calls))

    def test_runtime_deadline_bypasses_per_file_recovery(self):
        github = fixtures.FakeGitHub()
        def expired(path):
            raise ScanTimeout()
        github.call = expired
        with self.assertRaises(ScanTimeout):
            complete_files(github, fixtures.FILES, fixtures.BASE, fixtures.HEAD)

    def test_more_than_500_files_are_enumerated_without_omission(self):
        calls = []
        def transport(url, *args):
            page = int(url.rsplit("=", 1)[-1])
            calls.append(page)
            return [{"filename": str(index)} for index in range((page - 1) * 100, min(page * 100, 601))]
        files = GitHub("example/repo", 12, "key", transport).files(601)
        self.assertEqual(len(files), 601)
        self.assertEqual(files[-1]["filename"], "600")
        self.assertEqual(calls, list(range(1, 8)))


class ScanTests(unittest.TestCase):
    def large_files(self):
        text = "".join(f"safe line {number}\n" for number in range(15000)) + "allowAll()\n"
        return [{"filename": "coordinator/auth.go", "status": "added", "source_complete": True,
                 "patch": "@@ -0,0 +1,15001 @@\n" + "".join("+" + line for line in text.splitlines(keepends=True)),
                 "base_text": "", "head_text": text, "additions": 15001, "deletions": 0}]

    def test_every_byte_batched_and_finding_beyond_old_cutoffs_survives(self):
        files, calls = self.large_files(), []
        finding = dict(fixtures.FINDING, line=15001)
        def transport(url, key, body):
            request = json.loads(body["messages"][1]["content"])
            self.assertEqual(request["base_threat_model"], fixtures.THREAT)
            calls.append(request)
            found = [finding] if request["stage"] == "source" and any("allowAll()" in unit.get("text", "") for unit in request["units"]) else []
            if request["stage"] == "integration":
                found = [finding] if any(unit["findings"] for unit in request["units"]) else []
            return fixtures.completion(found, body=body)
        findings, _, limits = review(fixtures.THREAT, files, "key", transport=transport)
        self.assertEqual(findings, [finding])
        self.assertFalse(limits)
        source = [unit for call in calls if call["stage"] == "source" for unit in call["units"]]
        for field in ("patch", "head_text"):
            reconstructed = "".join(unit["text"] for unit in source if unit.get("kind") == field)
            self.assertEqual(reconstructed, files[0][field])
        self.assertGreater(len([call for call in calls if call["stage"] == "source"]), 2)
        self.assertEqual(calls[-1]["stage"], "integration")

    def test_integration_pass_can_discover_cross_file_finding(self):
        calls = []
        def transport(url, key, body):
            request = json.loads(body["messages"][1]["content"])
            calls.append(request["stage"])
            return fixtures.completion([fixtures.FINDING] if request["stage"] == "integration" else [], body=body)
        findings, _, _ = review(fixtures.THREAT, fixtures.FILES, "key", transport=transport)
        self.assertEqual(calls, ["source", "integration"])
        self.assertEqual(findings, [fixtures.FINDING])

    def test_integration_pass_can_dismiss_a_source_false_positive(self):
        def transport(url, key, body):
            request = json.loads(body["messages"][1]["content"])
            return fixtures.completion([fixtures.FINDING] if request["stage"] == "source" else [], body=body)
        findings, _, _ = review(fixtures.THREAT, fixtures.FILES, "key", transport=transport)
        self.assertFalse(findings)

    def test_same_count_smaller_summaries_get_another_integration_pass(self):
        file = dict(fixtures.FILES[0], source_complete=True, patch="", base_text="",
                    head_text="safe\n" * 16000)
        verbose = [dict(fixtures.FINDING, title=f"Candidate {i}", detail="x" * 1600) for i in range(24)]
        calls = []
        def transport(url, key, body):
            request = json.loads(body["messages"][1]["content"])
            calls.append((request["stage"], len(request["units"])))
            findings = verbose if request["stage"] == "source" else [fixtures.FINDING]
            return fixtures.completion(findings, body=body)
        findings, _, limits = review(fixtures.THREAT, [file], "key", transport=transport)
        self.assertEqual(findings, [fixtures.FINDING])
        self.assertFalse(limits)
        self.assertEqual(len([stage for stage, _ in calls if stage == "source"]), 2)
        self.assertEqual([count for stage, count in calls if stage == "integration"], [1, 1, 2])

    def test_same_count_nonshrinking_summaries_stop_as_incomplete(self):
        file = dict(fixtures.FILES[0], source_complete=True, patch="", base_text="",
                    head_text="safe\n" * 16000)
        for grows in (False, True):
            with self.subTest(grows=grows):
                calls = []
                def transport(url, key, body):
                    request = json.loads(body["messages"][1]["content"])
                    calls.append(request["stage"])
                    detail = "x" * (1600 if grows and request["stage"] == "integration" else 1599)
                    findings = [dict(fixtures.FINDING, title=f"Candidate {i}", detail=detail) for i in range(24)]
                    return fixtures.completion(findings, body=body)
                with self.assertRaisesRegex(ReviewUnavailable, "cannot be reduced"):
                    review(fixtures.THREAT, [file], "key", transport=transport)
                self.assertEqual(calls, ["source", "source", "integration", "integration"])

    def test_skipped_unit_or_late_batch_failure_never_returns_clean(self):
        for mode in ("missing", "late-failure"):
            calls = []
            def transport(url, key, body):
                calls.append(body)
                response = fixtures.completion([], body=body)
                if mode == "late-failure" and len(calls) > 1:
                    raise ReviewUnavailable("service unavailable")
                if mode == "missing":
                    result = json.loads(response["choices"][0]["message"]["content"])
                    result["covered_units"] = []
                    response["choices"][0]["message"]["content"] = json.dumps(result)
                return response
            with self.subTest(mode=mode), self.assertRaises(ReviewUnavailable):
                review(fixtures.THREAT, self.large_files(), "key", transport=transport)

    def test_complete_source_context_is_valid_evidence_outside_patch_hunks(self):
        files = complete_files(fixtures.FakeGitHub(), fixtures.FILES, fixtures.BASE, fixtures.HEAD)
        findings = [dict(fixtures.FINDING, side=side, line=1) for side in ("base", "head")]
        def transport(url, key, body):
            return fixtures.completion(findings, body=body)
        actual, _, limits = review(fixtures.THREAT, files, "key", transport=transport)
        self.assertEqual(actual, findings)
        self.assertFalse(limits)

    def test_empty_mode_only_finding_survives_scan_and_render(self):
        file = {"filename": "empty", "status": "modified", "source_complete": True,
                "base_text": "", "head_text": "", "base_mode": "100644", "head_mode": "100755", "patch": ""}
        requests = []
        finding = dict(fixtures.FINDING, file="empty", line=0)
        def transport(url, key, body):
            requests.append(json.loads(body["messages"][1]["content"]))
            return fixtures.completion([finding], body=body)
        findings, evidence, limits = review(fixtures.THREAT, [file], "key", transport=transport)
        self.assertEqual(findings, [finding])
        self.assertFalse(limits)
        metadata = requests[0]["units"][0]["metadata"]
        self.assertEqual(metadata["head_mode"], "100755")
        self.assertEqual(metadata["metadata_citation_sides"], ["base", "head"])
        body = render("example/repo", fixtures.HEAD, fixtures.BASE, "a/model", findings, evidence, limits)
        self.assertIn(f"[empty (file metadata)](https://github.com/example/repo/blob/{fixtures.HEAD}/empty)", body)
        self.assertNotIn("#L0", body)

    def test_empty_added_removed_and_renamed_files_have_extant_side_citations(self):
        for status, sides in (("added", ["head"]), ("removed", ["base"]), ("renamed", ["base", "head"])):
            with self.subTest(status=status):
                file = {"filename": "empty", "previous_filename": "old-empty", "status": status,
                        "source_complete": True, "patch": "", "base_text": "", "head_text": "",
                        "base_mode": "100644" if "base" in sides else None,
                        "head_mode": "100644" if "head" in sides else None}
                message, evidence, limits = prepare(fixtures.THREAT, [file])
                self.assertEqual(json.loads(message)["files"][0]["metadata_citation_sides"], sides)
                for side in sides:
                    finding = dict(fixtures.FINDING, file="empty", line=0, side=side)
                    self.assertEqual(validate_findings({"findings": [finding]}, evidence, fixtures.THREAT), [finding])
                    body = render("example/repo", fixtures.HEAD, fixtures.BASE, "a/model", [finding], evidence, limits)
                    sha, path = (fixtures.BASE, "old-empty") if side == "base" else (fixtures.HEAD, "empty")
                    self.assertIn(f"/blob/{sha}/{path})", body)
                    self.assertNotIn("#L0", body)

    def test_metadata_citations_reject_absent_nonempty_and_unread_sides(self):
        base = {"filename": "empty", "status": "added", "source_complete": True, "patch": "",
                "base_text": "", "head_text": "", "base_mode": None, "head_mode": "100644"}
        cases = [(base, "base"), (dict(base, head_text="not empty\n"), "head"),
                 (dict(base, source_complete=False), "head")]
        for file, side in cases:
            with self.subTest(file=file, side=side):
                _, evidence, _ = prepare(fixtures.THREAT, [file])
                finding = dict(fixtures.FINDING, file="empty", line=0, side=side)
                with self.assertRaises(ReviewUnavailable):
                    validate_findings({"findings": [finding]}, evidence, fixtures.THREAT)

    def test_unbatchable_line_fails_instead_of_truncating(self):
        with self.assertRaises(ReviewUnavailable):
            units([{"file": "huge", "head_text": "x" * 100000}])


if __name__ == "__main__":
    unittest.main()
