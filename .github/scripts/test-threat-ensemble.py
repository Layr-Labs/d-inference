#!/usr/bin/env python3
"""Regressions for independent reviewers, disagreement, and partial failures."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("fixtures", Path(__file__).with_name("test-threat-model-review.py"))
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
from threat_review.client import ReviewUnavailable, ScanTimeout
from threat_review.ensemble import DEFAULT_MODELS, configured_models, review_models
from threat_review.review import review
from threat_review.runner import run


class EnsembleTests(unittest.TestCase):
    def run_models(self, transport):
        return review_models(fixtures.THREAT, fixtures.FILES, "synthetic-key", DEFAULT_MODELS,
                             lambda *args: review(*args, transport=transport))

    def test_both_models_receive_complete_independent_source_and_integration(self):
        calls = {model: [] for model in DEFAULT_MODELS}
        def transport(url, key, body):
            request = json.loads(body["messages"][1]["content"])
            calls[body["model"]].append(request)
            self.assertNotIn("temperature", body)
            self.assertNotIn("top_p", body)
            self.assertTrue(body["provider"]["require_parameters"])
            self.assertEqual(key, "synthetic-key")
            return fixtures.completion([fixtures.FINDING], body=body)
        findings, _, limits, outcomes = self.run_models(transport)
        self.assertEqual(calls[DEFAULT_MODELS[0]], calls[DEFAULT_MODELS[1]])
        for requests in calls.values():
            self.assertEqual([r["stage"] for r in requests], ["source", "integration"])
            self.assertTrue(all(r["base_threat_model"] == fixtures.THREAT for r in requests))
        self.assertEqual(len(findings), 1)
        self.assertEqual(findings[0]["models"], list(DEFAULT_MODELS))
        self.assertFalse(limits)
        self.assertTrue(all(o["status"] == "completed" for o in outcomes))

    def test_clean_second_opinion_does_not_veto_first(self):
        for reporting_model in DEFAULT_MODELS:
            def transport(url, key, body):
                return fixtures.completion([fixtures.FINDING] if body["model"] == reporting_model else [], body=body)
            findings, _, _, _ = self.run_models(transport)
            self.assertEqual(findings[0]["models"], [reporting_model])

    def test_different_assessments_at_same_location_are_preserved(self):
        def transport(url, key, body):
            finding = dict(fixtures.FINDING, detail=body["model"])
            return fixtures.completion([finding], body=body)
        findings, _, _, _ = self.run_models(transport)
        self.assertEqual(len(findings), 2)

    def test_model_failure_preserves_other_review_and_sanitizes_errors(self):
        for failing_model in DEFAULT_MODELS:
            for failure in (ReviewUnavailable, RuntimeError):
                def transport(url, key, body):
                    if body["model"] == failing_model:
                        raise failure("synthetic-key raw request")
                    return fixtures.completion([fixtures.FINDING], body=body)
                findings, _, _, outcomes = self.run_models(transport)
                self.assertEqual(len(findings), 1)
                self.assertEqual(sum(o["status"] == "completed" for o in outcomes), 1)
                self.assertNotIn("synthetic-key", json.dumps(outcomes))

    def test_finding_cap_preserves_validated_advice_and_marks_reviewer_incomplete(self):
        for capped_stage in ("source", "integration"):
            with self.subTest(stage=capped_stage):
                capped = [dict(fixtures.FINDING, title=f"Finding {i:02d}") for i in range(32)]
                def transport(url, key, body):
                    stage = json.loads(body["messages"][1]["content"])["stage"]
                    findings = capped if body["model"] == DEFAULT_MODELS[0] and stage == capped_stage else []
                    return fixtures.completion(findings, body=body)
                findings, _, _, outcomes = self.run_models(transport)
                self.assertEqual(len(findings), 32)
                self.assertEqual({f["title"] for f in findings}, {f["title"] for f in capped})
                self.assertTrue(all(f["models"] == [DEFAULT_MODELS[0]] for f in findings))
                self.assertIn("finding capacity", outcomes[0]["status"])
                self.assertEqual(outcomes[1]["status"], "completed")

    def test_capped_invalid_response_does_not_publish_unvalidated_findings(self):
        capped = [dict(fixtures.FINDING, title=f"Finding {i}") for i in range(32)]
        capped[-1]["line"] = 999999
        findings, _, _, outcomes = self.run_models(lambda url, key, body: fixtures.completion(capped, body=body))
        self.assertEqual(findings, [])
        self.assertTrue(all(o["status"] != "completed" for o in outcomes))

    def test_deadline_preserves_completed_review_and_skips_remaining_calls(self):
        for expire_at in (0, 1):
            calls = []
            def reviewer(threat, files, key, model):
                calls.append(model)
                if len(calls) > expire_at:
                    raise ScanTimeout()
                return [fixtures.FINDING], {}, []
            findings, _, _, outcomes = review_models(fixtures.THREAT, fixtures.FILES, "key", DEFAULT_MODELS, reviewer)
            self.assertEqual(len(findings), expire_at)
            self.assertEqual(len(calls), expire_at + 1)
            self.assertEqual(len(outcomes), 2)
            self.assertIn("runtime limit", outcomes[-1]["status"])

    def test_configuration_defaults_legacy_override_and_invalid_inputs(self):
        self.assertEqual(configured_models({}), list(DEFAULT_MODELS))
        self.assertEqual(configured_models({"THREAT_REVIEW_MODEL": "vendor/one"}), ["vendor/one"])
        self.assertEqual(configured_models({"THREAT_REVIEW_MODEL": "old/model", "THREAT_REVIEW_MODELS": "a/one, b/two"}), ["a/one", "b/two"])
        for value in ("a/one,", "a/one,a/one", "a/one,b/two,c/three", "a/one,@everyone", " "):
            with self.subTest(value=value), self.assertRaises(ReviewUnavailable):
                configured_models({"THREAT_REVIEW_MODELS": value})

    def test_partial_clean_scan_still_posts_incomplete_with_model_status(self):
        for findings in ([], [fixtures.FINDING]):
            github = fixtures.FakeGitHub({"id": 17})
            def transport(url, key, body):
                if body["model"] == DEFAULT_MODELS[1]:
                    raise ReviewUnavailable("synthetic-key")
                return fixtures.completion(findings, body=body)
            with tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                (root / "docs").mkdir()
                (root / "docs/threat-model.yaml").write_text(fixtures.THREAT)
                result = run(fixtures.EVENT, root, {"OPENROUTER_API_KEY": "synthetic-key"}, github,
                             lambda *args: review(*args, transport=transport))
            self.assertIn("non-blocking", result)
            self.assertEqual(len(github.posts), 1)
            body = github.posts[0][1]
            self.assertIn("not confirmed resolved", body)
            self.assertIn("incomplete", body)
            self.assertIn("completed", body)
            self.assertNotIn("No actionable findings", body)
            self.assertNotIn("synthetic-key", body)
            if findings:
                self.assertIn("Raised by:", body)
                self.assertIn(fixtures.FINDING["title"], body)


if __name__ == "__main__":
    unittest.main()
