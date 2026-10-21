#!/usr/bin/env python3
"""Failure classification, public-log privacy, and bounded change-context tests."""
import json
import io
from contextlib import redirect_stderr
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from threat_review.change_context import batch_changes, changed_ranges, file_changes
from threat_review.diagnostics import ReviewFailure, failure_record, parse_object, request_id, write_diagnostics
from threat_review.review import model_call
from threat_review.budget_scan import Scanner
from threat_review.context import SOL
from types import SimpleNamespace


class DiagnosticsTests(unittest.TestCase):
    def test_json_syntax_has_position_and_category_without_private_text(self):
        with self.assertRaises(ReviewFailure) as caught:
            parse_object('{"PRIVATE_SOURCE":\nnot_json}')
        detail = caught.exception.diagnostic
        self.assertEqual(detail["code"], "RESPONSE_JSON_INVALID")
        self.assertEqual(detail["json_error"], "expected_value")
        self.assertEqual(detail["line"], 2)
        self.assertEqual(len(detail["response_sha256"]), 64)
        self.assertNotIn("PRIVATE_SOURCE", json.dumps(detail))

    def test_response_envelope_root_and_field_failures_are_distinct(self):
        def invoke(value):
            return model_call("", {}, "", "", "model", lambda *args: value)
        for value, expected in (
            ({}, "RESPONSE_ENVELOPE_INVALID"),
            ({"choices": [{"finish_reason": "stop", "message": {"content": "[]"}}]}, "RESPONSE_OBJECT_REQUIRED"),
            ({"choices": [{"finish_reason": "stop", "message": {"content": '{"PRIVATE":1}'}}]}, "RESPONSE_FIELDS_INVALID"),
        ):
            with self.subTest(expected=expected), self.assertRaises(ReviewFailure) as caught:
                invoke(value)
            self.assertEqual(caught.exception.diagnostic["code"], expected)
            self.assertNotIn("PRIVATE", json.dumps(caught.exception.diagnostic))

    def test_parser_limits_are_classified_without_exception_text(self):
        for value in ("[" * 20000 + "0" + "]" * 20000, '{"PRIVATE":' + "9" * 10000 + "}"):
            with self.subTest(size=len(value)), self.assertRaises(ReviewFailure) as caught:
                parse_object(value)
            self.assertEqual(caught.exception.diagnostic["code"], "RESPONSE_JSON_LIMIT")
            self.assertNotIn("PRIVATE", json.dumps(caught.exception.diagnostic))

    def test_unknown_exception_never_records_message_or_repr(self):
        value = failure_record(RuntimeError("sk-private credential"), {"stage": "setup"})
        self.assertEqual(value, {"code": "REVIEW_FAILED", "stage": "setup"})

    def test_request_id_is_uuid_only(self):
        for value in ({}, None, {"ResponseMetadata": None},
                      {"ResponseMetadata": {"RequestId": "private provider data"}}):
            self.assertIsNone(request_id(value))
        identity = "12345678-1234-1234-1234-123456789abc"
        self.assertEqual(request_id({"ResponseMetadata": {"RequestId": identity}}), identity)

    def test_diagnostics_artifact_excludes_findings_and_error_text(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "diagnostics.json"
            write_diagnostics({"THREAT_REVIEW_DIAGNOSTICS_FILE": str(path)}, {
                "findings": [{"detail": "PRIVATE_FINDING"}], "errors": ["PRIVATE_ERROR"],
                "diagnostics": [{"code": "RESPONSE_JSON_INVALID", "line": 2}]})
            saved = path.read_text()
            self.assertNotIn("PRIVATE", saved)
            self.assertEqual(json.loads(saved)["diagnostics"][0]["line"], 2)

    def test_batch_diagnostics_distinguish_coverage_analysis_and_decision(self):
        scanner = Scanner.__new__(Scanner)
        scanner.context = SimpleNamespace(text="")
        response = {"findings": [], "analysis": "ok", "covered_units": ["a", "b"],
                    "needs_deeper_review": False}
        for mutation, code in (
            ({"covered_units": ["a", "PRIVATE_ID"]}, "BATCH_ACKNOWLEDGMENT_INVALID"),
            ({"covered_units": ["a", "a"]}, "BATCH_ACKNOWLEDGMENT_INVALID"),
            ({"analysis": " " * 4001}, "BATCH_ANALYSIS_INVALID"),
            ({"needs_deeper_review": "PRIVATE_DECISION"}, "BATCH_DECISION_INVALID"),
        ):
            with self.subTest(code=code), self.assertRaises(ReviewFailure) as caught:
                scanner.validate(dict(response, **mutation), [{"id": "a"}, {"id": "b"}], {})
            detail = caught.exception.diagnostic
            self.assertEqual(detail["code"], code)
            self.assertNotIn("PRIVATE", json.dumps(detail))
            if "covered_units" in mutation:
                self.assertEqual(detail["missing_units"], 1)
            elif "analysis" in mutation:
                self.assertEqual(detail["analysis_characters"], 4001)

    def test_interrupted_diagnostic_write_preserves_previous_complete_artifact(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "diagnostics.json"
            env = {"THREAT_REVIEW_DIAGNOSTICS_FILE": str(path)}
            write_diagnostics(env, {"covered_units": 3, "diagnostics": []})
            original = path.read_text()
            errors = io.StringIO()
            with redirect_stderr(errors), patch.object(Path, "replace", side_effect=OSError("PRIVATE_DISK")):
                self.assertFalse(write_diagnostics(env, {"covered_units": 4, "diagnostics": []}))
            self.assertEqual(path.read_text(), original)
            self.assertIn("DIAGNOSTICS_WRITE_FAILED", errors.getvalue())
            self.assertNotIn("PRIVATE_DISK", errors.getvalue())


class ChangeContextTests(unittest.TestCase):
    def test_ranges_handle_insert_delete_and_multiple_hunks(self):
        patch = "@@ -1,2 +1,2 @@\n-old\n+new\n same\n@@ -8,2 +8,0 @@\n-gone\n-also gone"
        self.assertEqual(changed_ranges(patch), {"base": [[1, 1], [8, 9]], "head": [[1, 1]]})

    def test_incomplete_source_and_truncated_ranges_are_not_complete_maps(self):
        file = {"filename": "test.py", "status": "modified", "patch": "@@ -1 +1 @@\n-a\n+b"}
        self.assertFalse(file_changes([file])["test.py"]["range_map_complete"])
        file["source_complete"] = True
        with patch("threat_review.change_context.MAX_RANGES", 0):
            self.assertFalse(file_changes([file])["test.py"]["range_map_complete"])

    def test_oversized_change_context_fails_before_provider_call(self):
        changes = file_changes([{"filename": "test.py", "status": "modified", "patch": "large"}])
        with patch("threat_review.change_context.MAX_CONTEXT_BYTES", 1), self.assertRaises(ReviewFailure) as caught:
            batch_changes(changes, [{"metadata": {"file": "test.py"}}])
        self.assertEqual(caught.exception.diagnostic["code"], "CHANGE_CONTEXT_LIMIT")

    def test_multi_tier_integration_preserves_remaining_uncertainty(self):
        scanner = Scanner.__new__(Scanner)
        requests = []
        def call(model, stage, batch):
            requests.append(batch)
            return {"analysis": "compact", "findings": [],
                    "needs_deeper_review": any(item["needs_deeper_review"] for item in batch)}
        scanner.call = call
        # Force a real intermediate reduction before the final integration.
        def small_batches(items):
            yield from (items[index:index + 2] for index in range(0, len(items), 2))
        summaries = [{"id": str(i), "analysis": "source analysis " * 100, "findings": [],
                      "needs_deeper_review": i == 0} for i in range(3)]
        with patch("threat_review.budget_scan.batches", small_batches):
            result = scanner.integrate(SOL, summaries)
        self.assertEqual(len(requests), 3)
        self.assertTrue(requests[-1][0]["needs_deeper_review"])
        self.assertTrue(result["needs_deeper_review"])


if __name__ == "__main__":
    unittest.main()
