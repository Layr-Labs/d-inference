#!/usr/bin/env python3
"""Offline Bedrock request/fallback and merge-policy regressions."""
import copy
import json
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

from threat_review.bedrock import BedrockCalls, MODELS
from threat_review.budget_scan import SCHEMA
from threat_review.budget_runner import status_body
from threat_review.client import APIError, ReviewUnavailable, ScanTimeout
from threat_review.context import SONNET
from threat_review.merge_policy import clean, manual_override
from threat_review.membership import active_member, ORGANIZATION_ID
from threat_review.state import BudgetStopped


class SDKError(Exception):
    def __init__(self, code):
        self.response = {"Error": {"Code": code, "Message": "private provider detail"}}


class Client:
    def __init__(self):
        self.requests = []
        self.error = None
        self.response = {"usage": {"inputTokens": 12, "outputTokens": 8}, "stopReason": "end_turn",
                         "output": {"message": {"content": [{"reasoningContent": "private reasoning"},
                                                              {"text": '{"findings":[]}' }]}}}

    def converse(self, **request):
        self.requests.append(request)
        if self.error:
            raise self.error
        return self.response


class Backup:
    def __init__(self, *args, **kwargs):
        self.calls = []
        self.stopped = None

    def __call__(self, *args):
        self.calls.append(copy.deepcopy(args))
        return {"backup": True}

    def metrics(self):
        return {"actual_usd": 0, "unreconciled_reserved_usd": 0, "requests": len(self.calls)}


class BedrockTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "usage.jsonl"
        self.env = {"BEDROCK_SCAN_PROFILES": json.dumps({a: f"arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/{a}"
                                                        for a in ("sonnet", "opus", "sol")}),
                    "BEDROCK_SCAN_USAGE_FILE": str(self.path), "GITHUB_RUN_ID": "123",
                    "GITHUB_REPOSITORY": "example/repo", "GITHUB_WORKFLOW": "Review (conditional)"}
        self.client = Client()
        self.calls = BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env,
                                 client=self.client, fallback_factory=Backup)
        self.payload = {"model": SONNET, "messages": [{"content": "system instructions"},
                                                      {"content": "private source code"}],
                        "response_format": {"json_schema": {"schema": {"type": "object"}}}}

    def invoke(self):
        return self.calls("https://openrouter.ai/api/v1/chat/completions", "synthetic", self.payload)

    def test_profile_schema_and_usage_without_source_or_reasoning_in_ledger(self):
        result = self.invoke()
        request = self.client.requests[0]
        self.assertTrue(request["modelId"].endswith("/sonnet"))
        self.assertIn('"type": "object"', request["system"][0]["text"])
        self.assertNotIn("outputConfig", request)
        self.assertEqual(result["choices"][0]["message"]["content"], '{"findings":[]}')
        ledger = self.path.read_text()
        for private in ("private source code", "private reasoning", "synthetic", "system instructions"):
            self.assertNotIn(private, ledger)
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 0)
        self.assertEqual(self.calls.metrics()["bedrock_input_tokens"], 12)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_explicit_availability_rejection_uses_backup_once(self):
        self.client.error = SDKError("ThrottlingException")
        self.assertEqual(self.invoke(), {"backup": True})
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(len(self.calls.fallback.calls), 1)
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 1)
        self.assertNotIn("private provider detail", self.path.read_text())

    def test_sonnet_availability_fallback_preserves_selected_model_identity(self):
        self.client.error = SDKError("AccessDeniedException")
        self.assertEqual(self.invoke(), {"backup": True})
        self.assertEqual(self.payload["model"], "anthropic/claude-sonnet-5.5")
        self.assertTrue(self.client.requests[0]["modelId"].endswith("/sonnet"))
        self.assertEqual(self.calls.fallback.calls[0][2]["model"], self.payload["model"])

    def test_synthetic_smoke_uses_production_contract_for_each_model_and_pass(self):
        smoke = runpy.run_path(str(Path(__file__).with_name("threat-bedrock-smoke.py")))["smoke_model"]
        files = [{"filename": "smoke.py", "status": "modified", "additions": 1, "deletions": 1,
                  "patch": "@@ -1 +1 @@\n-answer = 40 + 2\n+answer = 42",
                  "base_text": "answer = 40 + 2\n", "head_text": "answer = 42\n"}]
        threat = "threats:\n  - id: T-SMOKE\n    description: Preserve the answer.\n"
        replies = []
        def converse(**request):
            self.client.requests.append(request)
            message = json.loads(request["messages"][0]["content"][0]["text"])
            replies.append(message["stage"])
            schema = json.loads(request["system"][0]["text"].split(
                "\nReturn only JSON matching this schema:\n", 1)[1])
            self.assertEqual(schema, SCHEMA)
            result = {"findings": [], "covered_units": [u["id"] for u in message["units"]],
                      "analysis": "The arithmetic result is unchanged.", "needs_deeper_review": False}
            if invalid is not None:
                if invalid == "missing":
                    del result["needs_deeper_review"]
                else:
                    result["needs_deeper_review"] = invalid
            response = copy.deepcopy(self.client.response)
            response["output"]["message"]["content"] = [{"text": json.dumps(result)}]
            return response
        self.client.converse = converse
        invalid = None
        for model in MODELS:
            smoke(threat, files, model, self.calls)
        self.assertEqual(replies, ["source", "integration"] * 3)
        self.assertEqual(self.calls.calls, 6)
        self.assertEqual(self.calls.unknown, 0)
        for invalid in ("missing", "false", 0):
            with self.subTest(invalid=invalid), self.assertRaises((ReviewUnavailable, ValueError)):
                smoke(threat, files, SONNET, self.calls)
        invalid = True
        self.assertEqual(smoke(threat, files, SONNET, self.calls),
                         {"source": True, "integration": True})
        self.assertEqual(self.calls.fallback.calls, [])

    def test_unknown_failure_does_not_resample(self):
        for error in (TimeoutError(), SDKError("ModelTimeoutException"), SDKError("InternalServerException")):
            self.client.error = error
            with self.assertRaises(ReviewUnavailable):
                self.invoke()
        self.assertEqual(self.calls.fallback.calls, [])

    def test_scan_deadline_propagates_without_backup(self):
        self.client.error = ScanTimeout()
        with self.assertRaises(ScanTimeout):
            self.invoke()
        self.assertEqual(self.calls.fallback.calls, [])

    def test_output_refusal_or_truncation_never_falls_back(self):
        for stop in ("max_tokens", "guardrail_intervened", "content_filtered"):
            self.client.response["stopReason"] = stop
            with self.assertRaises(ReviewUnavailable):
                self.invoke()
        self.assertEqual(self.calls.fallback.calls, [])

    def test_malformed_json_is_left_for_strict_validator_without_backup(self):
        self.client.response["output"]["message"]["content"] = [{"text": "not JSON"}]
        self.assertEqual(self.invoke()["choices"][0]["message"]["content"], "not JSON")
        self.assertEqual(self.calls.fallback.calls, [])

    def test_missing_usage_cannot_be_reported_as_zero(self):
        self.client.response["usage"] = {}
        with self.assertRaises(ReviewUnavailable):
            self.invoke()
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_request_limit_cannot_be_bypassed_with_backup(self):
        self.calls.limit = 1
        self.invoke()
        with self.assertRaises(BudgetStopped):
            self.invoke()
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_missing_aws_credentials_uses_explicit_backup(self):
        self.calls.client = None
        self.assertEqual(self.invoke(), {"backup": True})
        self.assertEqual(self.client.requests, [])

    def test_missing_profiles_does_not_silently_switch(self):
        self.env["BEDROCK_SCAN_PROFILES"] = "{}"
        with self.assertRaises(ReviewUnavailable):
            BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env, fallback_factory=Backup)

    def test_cannot_call_model_when_usage_record_fails(self):
        self.path.mkdir()
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.client.requests, [])


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.head, self.base = "a" * 40, "b" * 40
        self.report = {"head": self.head, "base": self.base, "review": {
            "integration_completed": True, "covered_units": 3, "total_units": 3,
            "depth_batches_pending": 0, "findings": [], "errors": [], "limited_files": []}}
        self.pull = {"number": 1, "head": {"sha": self.head}, "user": {"id": 1}}
        self.reviews = [{"id": 1, "state": "APPROVED", "user": {"id": 2, "login": "maintainer", "type": "User"},
                         "commit_id": self.head, "body": f"Security override: {self.head}\nReason: Reviewed the risk and accepted it."}]
        self.permission = "write"

    def call(self, path):
        if "/reviews?" in path:
            return self.reviews
        return {"permission": self.permission}

    def test_complete_scan_allows_low_advice_only(self):
        self.assertTrue(clean(self.report, self.head, self.base))
        self.report["review"]["findings"] = [{"severity": "low"}]
        self.assertTrue(clean(self.report, self.head, self.base))
        for severity in ("medium", "high", "unknown"):
            self.report["review"]["findings"] = [{"severity": severity}]
            self.assertFalse(clean(self.report, self.head, self.base))

    def test_conditional_comment_explains_gate_instead_of_claiming_advisory_only(self):
        body = status_body("example/repo", self.head, self.base, self.base,
                           self.report["review"], {}, clearance=True)
        self.assertIn("manual security override", body)
        self.assertNotIn("never requests changes or blocks merging", body)
        self.assertNotIn("review — advisory", body)

    def test_absent_stale_and_incomplete_scans_never_clear(self):
        for value in (None, {}, {"head": "c" * 40, "base": self.base, "review": self.report["review"]}):
            self.assertFalse(clean(value, self.head, self.base))
        for field, value in (("errors", ["unavailable"]), ("limited_files", ["binary"]),
                             ("depth_batches_pending", 1), ("covered_units", 2),
                             ("integration_completed", False), ("total_units", True)):
            report = copy.deepcopy(self.report)
            report["review"][field] = value
            self.assertFalse(clean(report, self.head, self.base), field)

    def test_current_independent_formal_override(self):
        self.assertEqual(manual_override(self, self.pull), "maintainer")

    def test_self_bot_outsider_stale_and_reasonless_reviews_do_not_override(self):
        original = copy.deepcopy(self.reviews)
        for field, value in (("commit_id", "c" * 40), ("state", "COMMENTED"),
                             ("body", "Approved"), ("body", f"Security override: {self.head}"),
                             ("user", {"id": 1, "login": "author", "type": "User"}),
                             ("user", {"id": 2, "login": "bot", "type": "Bot"})):
            self.reviews = copy.deepcopy(original)
            self.reviews[0][field] = value
            self.assertIsNone(manual_override(self, self.pull), field)
        self.reviews = original
        self.permission = "read"
        self.assertIsNone(manual_override(self, self.pull))

    def test_dismissal_or_requested_changes_revokes_override(self):
        for state in ("DISMISSED", "CHANGES_REQUESTED"):
            self.reviews = [self.reviews[0], dict(self.reviews[0], id=2, state=state)]
            if state == "CHANGES_REQUESTED":
                with self.assertRaises(ReviewUnavailable):
                    manual_override(self, self.pull)
            else:
                self.assertIsNone(manual_override(self, self.pull))


class MembershipTests(unittest.TestCase):
    def setUp(self):
        self.author = {"id": 123, "login": "member", "type": "User"}
        self.membership = {"state": "active", "role": "member",
                           "organization": {"id": ORGANIZATION_ID}, "user": dict(self.author)}
        self.calls = []

    def transport(self, url, token):
        self.calls.append((url, token))
        self.assertEqual(url, "https://api.github.com/orgs/Layr-Labs/memberships/member")
        self.assertEqual(token, "membership-only")
        return self.membership

    def test_active_member_and_admin_with_matching_immutable_id(self):
        for role in ("member", "admin"):
            self.membership["role"] = role
            self.assertTrue(active_member(self.author, "membership-only", self.transport))

    def test_association_or_repository_access_cannot_replace_membership(self):
        self.author.update(author_association="MEMBER", permissions={"admin": True})
        self.membership["state"] = "pending"
        self.assertFalse(active_member(self.author, "membership-only", self.transport))
        for status in (403, 404, 500):
            def denied(url, token):
                raise APIError(status)
            if status == 404:
                self.assertFalse(active_member(self.author, "membership-only", denied))
            else:
                with self.assertRaises(ReviewUnavailable):
                    active_member(self.author, "membership-only", denied)

    def test_no_token_bot_and_malformed_identity_never_lookup_or_clear(self):
        self.assertFalse(active_member(self.author, "", self.transport))
        for author in (None, {}, dict(self.author, type="Bot"), dict(self.author, id=True),
                       dict(self.author, login="member/other")):
            self.assertFalse(active_member(author, "membership-only", self.transport))
        self.assertEqual(self.calls, [])

    def test_wrong_organization_user_role_and_malformed_response_fail_closed(self):
        original = copy.deepcopy(self.membership)
        for field, value in (("organization", {"id": 1}), ("organization", None),
                             ("user", dict(self.author, id=999)), ("user", dict(self.author, type="Bot")),
                             ("user", dict(self.author, login="someone-else")), ("role", "billing_manager"),
                             ("state", "pending")):
            self.membership = dict(original, **{field: value})
            self.assertFalse(active_member(self.author, "membership-only", self.transport), field)
        self.membership = []
        self.assertFalse(active_member(self.author, "membership-only", self.transport))

    def test_membership_is_rechecked_after_revocation(self):
        self.assertTrue(active_member(self.author, "membership-only", self.transport))
        self.membership["state"] = "pending"
        self.assertFalse(active_member(self.author, "membership-only", self.transport))
        self.assertEqual(len(self.calls), 2)


class MemberGateTests(unittest.TestCase):
    def setUp(self):
        self.head, self.base = "a" * 40, "b" * 40
        self.pull = {"number": 1, "head": {"sha": self.head}, "base": {"sha": self.base, "ref": "master"},
                     "state": "open", "draft": False, "changed_files": 1,
                     "user": {"id": 123, "login": "member", "type": "User"}}
        self.reviews, self.member = [], True
        self.lookups = 0
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        event, report = root / "event.json", root / "report.json"
        event.write_text(json.dumps({"pull_request": self.pull}))
        report.write_text(json.dumps({"repository": "Layr-Labs/d-inference", "head": self.head,
          "base": self.base, "diff_base": self.base, "review": {"integration_completed": True,
          "covered_units": 1, "total_units": 1, "depth_batches_pending": 0,
          "findings": [], "errors": [], "limited_files": []}}))
        self.env = {"THREAT_REVIEW_REQUIRE_CLEARANCE": "true", "GITHUB_EVENT_PATH": str(event),
                    "THREAT_REVIEW_RESULT_FILE": str(report), "GITHUB_REPOSITORY": "Layr-Labs/d-inference",
                    "GH_TOKEN": "repo-only", "THREAT_REVIEW_MEMBERSHIP_TOKEN": "membership-only"}
        self.main = runpy.run_path(str(Path(__file__).with_name("threat-review-gate.py")))["main"]

    def call(self, path):
        return self.reviews if "/reviews?" in path else {"permission": "write"}

    def files(self, count):
        return [{"filename": "coordinator/api/access/authorize.go"}]

    def member_lookup(self, author, token):
        self.lookups += 1
        self.assertEqual(author, self.pull["user"])
        self.assertEqual(token, "membership-only")
        return self.member

    def evaluate(self):
        class Repo:
            pass
        github = Repo()
        github.pull, github.call, github.files = lambda: self.pull, self.call, self.files
        with patch.dict("os.environ", self.env, clear=True), patch("sys.argv", ["gate", "after"]), \
             patch.dict(self.main.__globals__, GitHub=lambda *args: github, active_member=self.member_lookup):
            return self.main()

    def test_clean_active_member_clears_but_clean_outsider_does_not(self):
        self.assertEqual(self.evaluate(), 0)
        self.member = False
        self.assertEqual(self.evaluate(), 1)
        self.assertEqual(self.lookups, 2)

    def test_outsider_still_has_explicit_independent_human_review_path(self):
        self.member = False
        self.reviews = [{"id": 1, "state": "APPROVED", "commit_id": self.head,
                        "user": {"id": 456, "login": "maintainer", "type": "User"},
                        "body": f"Security override: {self.head}\nReason: Independently reviewed this external contribution."}]
        self.assertEqual(self.evaluate(), 0)
        self.assertEqual(self.lookups, 0)

    def test_prior_membership_cannot_clear_a_later_evaluation(self):
        self.assertEqual(self.evaluate(), 0)
        self.member = False
        self.pull["author_association"] = "MEMBER"
        self.assertEqual(self.evaluate(), 1)


if __name__ == "__main__":
    unittest.main()
