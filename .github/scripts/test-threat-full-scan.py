#!/usr/bin/env python3
"""Coverage regressions for immutable sources and multi-pass full PR scanning."""
import base64
import importlib.util
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("fixtures", Path(__file__).with_name("test-threat-model-review.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
from threat_review.client import GitHub, ReviewUnavailable, ScanTimeout
from threat_review.review import prepare, review
from threat_review.source import Sources, complete_files
from threat_review.scan import units


class SourceTests(unittest.TestCase):
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

    def test_empty_mode_only_file_is_scanned_as_metadata(self):
        file = {"filename": "empty", "status": "modified", "source_complete": True,
                "base_text": "", "head_text": "", "base_mode": "100644", "head_mode": "100755", "patch": ""}
        requests = []
        def transport(url, key, body):
            requests.append(json.loads(body["messages"][1]["content"]))
            return fixtures.completion([], body=body)
        findings, _, limits = review(fixtures.THREAT, [file], "key", transport=transport)
        self.assertFalse(findings or limits)
        self.assertEqual(requests[0]["units"][0]["metadata"]["head_mode"], "100755")

    def test_unbatchable_line_fails_instead_of_truncating(self):
        with self.assertRaises(ReviewUnavailable):
            units([{"file": "huge", "head_text": "x" * 100000}])


if __name__ == "__main__":
    unittest.main()
