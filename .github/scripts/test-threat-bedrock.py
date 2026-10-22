#!/usr/bin/env python3
"""Offline Bedrock request/fallback and merge-policy regressions."""
import copy
import json
from pathlib import Path
import runpy
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

from threat_review.bedrock import BedrockCalls, MODELS
from threat_review.budget_scan import SCHEMA, Scanner
from threat_review.budget_runner import status_body
from threat_review.client import APIError, ReviewUnavailable, ScanTimeout
from threat_review.context import SONNET, SOL, ThreatContext
from threat_review.review import model_call
from threat_review.structured_output import bedrock_schema
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
        self.assertEqual(json.loads(request["outputConfig"]["textFormat"]["structure"]["jsonSchema"]["schema"]),
                         {"type": "object"})
        self.assertEqual(result["choices"][0]["message"]["content"], '{"findings":[]}')
        ledger = self.path.read_text()
        for private in ("private source code", "private reasoning", "synthetic", "system instructions"):
            self.assertNotIn(private, ledger)
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 0)
        self.assertEqual(self.calls.metrics()["bedrock_input_tokens"], 12)
        self.assertEqual(self.calls.metrics()["bedrock_cache_read_input_tokens"], 0)
        self.assertEqual(self.calls.metrics()["bedrock_cache_write_input_tokens"], 0)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_sol_cache_input_usage_is_preserved_in_ledger_metrics_and_report(self):
        # Token counts from the bounded local Sol response; no content retained.
        self.payload["model"] = SOL
        self.client.response["usage"] = {"inputTokens": 2, "outputTokens": 123,
                                         "cacheReadInputTokens": 0, "cacheWriteInputTokens": 2093}
        self.invoke()
        self.client.response["usage"] = {"inputTokens": 3, "outputTokens": 40,
                                         "cacheReadInputTokens": 2093, "cacheWriteInputTokens": 0}
        self.invoke()
        metrics = self.calls.metrics()
        self.assertEqual(metrics["bedrock_input_tokens"], 5)
        self.assertEqual(metrics["bedrock_cache_read_input_tokens"], 2093)
        self.assertEqual(metrics["bedrock_cache_write_input_tokens"], 2093)
        self.assertEqual(metrics["bedrock_output_tokens"], 163)
        self.assertEqual(metrics["bedrock_unknown_usage"], 0)
        rows = [json.loads(line) for line in self.path.read_text().splitlines()]
        responses = [row for row in rows if row["event"] == "response"]
        self.assertEqual(responses[0]["cache_write_input_tokens"], 2093)
        self.assertEqual(responses[1]["cache_read_input_tokens"], 2093)
        body = status_body("example/repo", "a" * 40, "b" * 40, "b" * 40, metrics, {})
        self.assertIn("5 uncached + 2093 cache-read + 2093 cache-write input / 163 output tokens", body)

    def test_legacy_snapshot_does_not_invent_zero_cache_usage(self):
        metrics = self.calls.metrics()
        del metrics["bedrock_cache_read_input_tokens"], metrics["bedrock_cache_write_input_tokens"]
        body = status_body("example/repo", "a" * 40, "b" * 40, "b" * 40, metrics, {})
        self.assertIn("unavailable cache input", body)

    def test_invalid_cache_usage_remains_unknown_without_fallback(self):
        for field in ("cacheReadInputTokens", "cacheWriteInputTokens"):
            for invalid in (None, True, -1, "2", 1.5):
                with self.subTest(field=field, invalid=invalid):
                    self.calls = BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env,
                                             client=self.client, fallback_factory=Backup)
                    before = len(self.client.requests)
                    self.client.response["usage"] = {"inputTokens": 2, "outputTokens": 123, field: invalid}
                    self.assertEqual(self.invoke()["choices"][0]["message"]["content"], '{"findings":[]}')
                    self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 1)
                    self.assertEqual(self.calls.metrics()["bedrock_input_tokens"], 0)
                    self.assertEqual(self.calls.stop_diagnostic["code"], "BEDROCK_USAGE_MISSING")
                    with self.assertRaises(BudgetStopped):
                        self.invoke()
                    self.assertEqual(len(self.client.requests), before + 1)
                    self.assertEqual(self.calls.fallback.calls, [])

    def test_explicit_availability_rejection_uses_backup_once(self):
        self.client.error = SDKError("ThrottlingException")
        self.assertEqual(self.invoke(), {"backup": True})
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(len(self.calls.fallback.calls), 1)
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 1)
        self.assertNotIn("private provider detail", self.path.read_text())

    def test_native_schema_preserves_structure_and_local_constraints_for_every_model(self):
        original = copy.deepcopy(SCHEMA)
        self.payload["response_format"]["json_schema"]["schema"] = SCHEMA
        for model in MODELS:
            self.payload["model"] = model
            self.invoke()
            request = self.client.requests[-1]
            native = json.loads(request["outputConfig"]["textFormat"]["structure"]["jsonSchema"]["schema"])
            self.assertEqual(native, bedrock_schema(SCHEMA))
            self.assertEqual(native["required"], SCHEMA["required"])
            self.assertFalse(native["additionalProperties"])
            self.assertEqual(native["properties"]["needs_deeper_review"], {"type": "boolean"})
            self.assertNotIn("maxLength", native["properties"]["analysis"])
            self.assertIn('"minLength": 1', native["properties"]["analysis"]["description"])
            self.assertEqual(self.calls.last_request["response_format"], "json_schema")
            if model == SOL:
                self.assertEqual(request["additionalModelRequestFields"], {"text": {"format": {"strict": True}}})
            else:
                self.assertNotIn("additionalModelRequestFields", request)
        self.assertEqual(SCHEMA, original)

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
            expected_schema = copy.deepcopy(SCHEMA)
            if message["stage"] == "integration":
                expected_schema["properties"]["covered_units"]["items"]["enum"] = [u["id"] for u in message["units"]]
            self.assertEqual(schema, expected_schema)
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
        self.assertEqual(self.invoke()["choices"][0]["message"]["content"], '{"findings":[]}')
        self.assertTrue(self.calls.stopped)
        self.assertEqual(self.calls.stop_diagnostic["code"], "BEDROCK_USAGE_MISSING")
        with self.assertRaises(BudgetStopped) as caught:
            self.invoke()
        self.assertEqual(caught.exception.diagnostic, self.calls.stop_diagnostic)
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_response_usage_write_failure_preserves_text_but_stops_all_later_requests(self):
        record = self.calls.record
        def unavailable(**fields):
            if fields["event"] == "response":
                raise OSError("PRIVATE_USAGE_PATH")
            return record(**fields)
        with patch.object(self.calls, "record", side_effect=unavailable):
            response = self.invoke()
        self.assertEqual(response["choices"][0]["message"]["content"], '{"findings":[]}')
        self.assertEqual(self.calls.stop_diagnostic["code"], "BEDROCK_USAGE_RECORD_FAILED")
        self.assertEqual(self.calls.metrics()["bedrock_unknown_usage"], 1)
        self.assertEqual(self.calls.metrics()["bedrock_input_tokens"], 0)
        self.assertNotIn("PRIVATE_USAGE_PATH", json.dumps(self.calls.stop_diagnostic))
        self.assertNotIn("PRIVATE_USAGE_PATH", self.calls.stopped)
        # Even recovered native service or unavailable credentials cannot spend.
        self.calls.client = None
        with self.assertRaises(BudgetStopped):
            self.invoke()
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_unknown_usage_does_not_bypass_response_validation(self):
        self.client.response["usage"] = {}
        self.client.response["output"]["message"]["content"] = [{"text": "PRIVATE_INVALID_JSON"}]
        with self.assertRaises(ReviewUnavailable) as caught:
            model_call("source", {}, "", "synthetic", SONNET, self.calls)
        self.assertEqual(caught.exception.diagnostic["code"], "RESPONSE_JSON_INVALID")
        self.assertTrue(self.calls.stopped)
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_unknown_usage_does_not_accept_truncated_response(self):
        self.client.response["usage"] = {}
        self.client.response["stopReason"] = "max_tokens"
        with self.assertRaises(ReviewUnavailable) as caught:
            self.invoke()
        self.assertEqual(caught.exception.diagnostic["code"], "BEDROCK_RESPONSE_INCOMPLETE")
        self.assertTrue(self.calls.stopped)
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_request_limit_cannot_be_bypassed_with_backup(self):
        self.calls.limit = 1
        self.invoke()
        with self.assertRaises(BudgetStopped):
            self.invoke()
        self.assertEqual(len(self.client.requests), 1)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_workload_policy_admits_stages_instead_of_using_legacy_fixed_limit(self):
        self.env.update(BEDROCK_SCAN_CALL_POLICY="workload", BEDROCK_SCAN_MAX_CALLS="1")
        self.calls = BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env,
                                 client=self.client, fallback_factory=Backup)
        with self.assertRaises(BudgetStopped):
            self.invoke()  # No unplanned native call, even before the first stage.
        self.calls.plan_calls(30)
        self.assertEqual(self.calls.limit, 31)  # source + one shared repair
        for _ in range(30):
            self.invoke()
        self.calls.plan_calls(1)  # actual cross-file integration
        self.invoke()
        self.assertEqual(len(self.client.requests), 31)
        self.assertEqual(self.calls.metrics()["bedrock_planned_calls"], 31)
        self.assertEqual(self.calls.limit, 32)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_generous_workload_defaults_and_emergency_ceiling_are_still_bounded(self):
        self.assertEqual(self.calls.ceiling, 12)
        self.assertEqual(self.calls.output_tokens, 4096)  # fixed diagnostic probes retain their limits
        self.env.update(BEDROCK_SCAN_CALL_POLICY="workload")
        self.calls = BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env,
                                 client=self.client, fallback_factory=Backup)
        self.assertEqual(self.calls.ceiling, 500)
        self.assertEqual(self.calls.output_tokens, 16384)
        self.calls.plan_calls(499)
        for _ in range(500):
            self.invoke()  # planned work plus the one shared repair slot
        with self.assertRaises(BudgetStopped):
            self.invoke()
        self.assertEqual(len(self.client.requests), 500)
        self.assertEqual(self.client.requests[-1]["inferenceConfig"]["maxTokens"], 16384)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_larger_workload_has_time_for_output_without_sdk_retries(self):
        for policy, seconds in (("fixed", 240), ("workload", 600)):
            with self.subTest(policy=policy):
                configs = []
                def config(**values):
                    configs.append(values)
                    return values
                modules = {"boto3": SimpleNamespace(client=lambda *args, **kwargs: self.client),
                           "botocore": SimpleNamespace(), "botocore.config": SimpleNamespace(Config=config)}
                env = dict(self.env, BEDROCK_SCAN_CALL_POLICY=policy, BEDROCK_SCAN_CREDENTIALS_READY="true")
                self.calls = BedrockCalls(None, 1, "123-1", "synthetic", "index", env, fallback_factory=Backup)
                self.calls.plan_calls(1)
                with patch.dict("sys.modules", modules):
                    self.invoke()
                self.assertEqual(configs, [{"connect_timeout": 10, "read_timeout": seconds,
                                            "retries": {"total_max_attempts": 1, "mode": "standard"}}])

    def test_workload_emergency_ceiling_stops_before_the_unadmitted_stage(self):
        self.env.update(BEDROCK_SCAN_CALL_POLICY="workload", BEDROCK_SCAN_MAX_WORKLOAD_CALLS="3")
        self.calls = BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env,
                                 client=self.client, fallback_factory=Backup)
        self.calls.plan_calls(2)
        self.invoke()
        self.invoke()
        with self.assertRaises(BudgetStopped) as caught:
            self.calls.plan_calls(1)
        self.assertEqual(caught.exception.diagnostic["code"], "BEDROCK_WORKLOAD_LIMIT")
        with self.assertRaises(BudgetStopped):
            self.invoke()
        self.assertEqual(len(self.client.requests), 2)
        self.assertEqual(self.calls.fallback.calls, [])

    def test_invalid_call_policies_and_ceiling_cannot_expand_paid_work(self):
        for config in ({"BEDROCK_SCAN_CALL_POLICY": "unlimited"},
                       {"BEDROCK_SCAN_CALL_POLICY": "workload", "BEDROCK_SCAN_MAX_WORKLOAD_CALLS": "501"},
                       {"BEDROCK_SCAN_CALL_POLICY": "workload", "BEDROCK_SCAN_MAX_WORKLOAD_CALLS": "0"},
                       {"BEDROCK_SCAN_CALL_POLICY": "fixed", "BEDROCK_SCAN_MAX_CALLS": "101"},
                       {"BEDROCK_SCAN_CALL_POLICY": "workload", "BEDROCK_SCAN_MAX_OUTPUT_TOKENS": "16385"}):
            with self.subTest(config=config), self.assertRaises(ReviewUnavailable):
                BedrockCalls(None, 1, "123-1", "synthetic", "index", dict(self.env, **config),
                             client=self.client, fallback_factory=Backup)
        self.assertEqual(self.client.requests, [])

    def test_missing_aws_credentials_uses_explicit_backup(self):
        self.calls.client = None
        self.assertEqual(self.invoke(), {"backup": True})
        self.assertEqual(self.client.requests, [])

    def test_missing_profiles_does_not_silently_switch(self):
        self.env["BEDROCK_SCAN_PROFILES"] = "{}"
        with self.assertRaises(ReviewUnavailable):
            BedrockCalls(None, 1, "123-1", "synthetic", "index", self.env, fallback_factory=Backup)

    def test_provider_metadata_correlates_errors_without_recording_bodies(self):
        self.client.response["ResponseMetadata"] = {"RequestId": "12345678-1234-1234-1234-123456789abc"}
        self.client.response["stopReason"] = "max_tokens"
        with self.assertRaises(ReviewUnavailable) as caught:
            self.invoke()
        self.assertEqual(caught.exception.diagnostic["code"], "BEDROCK_RESPONSE_INCOMPLETE")
        self.assertEqual(self.calls.last_request["stop_reason"], "max_tokens")
        self.assertEqual(self.calls.last_request["call"], 1)
        self.assertIn("12345678-1234-1234-1234-123456789abc", self.path.read_text())
        self.assertNotIn("private", self.path.read_text())

    def test_sdk_validation_error_preserves_code_without_provider_message(self):
        self.client.error = SDKError("ValidationException")
        with self.assertRaises(ReviewUnavailable) as caught:
            self.invoke()
        self.assertEqual(caught.exception.diagnostic["code"], "BEDROCK_REQUEST_FAILED")
        self.assertEqual(self.calls.last_request["sdk_code"], "ValidationException")
        self.assertNotIn("private provider detail", self.path.read_text())

    def test_malformed_sdk_error_remains_content_free(self):
        self.client.error = SDKError("ValidationException")
        self.client.error.response["Error"] = {"Code": ["private provider detail"]}
        with self.assertRaises(ReviewUnavailable) as caught:
            self.invoke()
        self.assertEqual(caught.exception.diagnostic["code"], "BEDROCK_REQUEST_FAILED")
        self.assertEqual(self.calls.last_request["sdk_code"], "RequestFailure")
        self.assertNotIn("private provider detail", self.path.read_text())

    def test_fallback_failure_has_current_backup_call_identity(self):
        self.client.error = SDKError("ThrottlingException")
        def fail(*args):
            self.calls.fallback.last_request = {"provider": "openrouter", "call": 7}
            raise APIError(503)
        with patch.object(Backup, "__call__", side_effect=fail), self.assertRaises(APIError):
            self.invoke()
        self.assertEqual(self.calls.last_request, {"provider": "openrouter", "bedrock_call": 1, "call": 7})

    def test_cannot_call_model_when_usage_record_fails(self):
        self.path.mkdir()
        with self.assertRaises(OSError):
            self.invoke()
        self.assertEqual(self.client.requests, [])


class WorkloadScanTests(unittest.TestCase):
    def large_scan(self, lines):
        context = ThreatContext("threats:\n  - id: T-TEST\n    description: Preserve security.\n")
        files = [{"filename": "encrypt.py", "status": "added", "source_complete": True,
                  "head_text": ("x" * 999 + "\n") * lines, "patch": ""}]
        requests, progress = [], []
        outer = self
        class Native:
            def converse(self, **request):
                outer.assertEqual(request["inferenceConfig"]["maxTokens"], 16384)
                message = json.loads(request["messages"][0]["content"][0]["text"])
                requests.append((request["modelId"].rsplit("/", 1)[-1], message["stage"]))
                result = {"findings": [], "covered_units": message["expected_covered_units"],
                          "analysis": "a" * 4000, "needs_deeper_review": False}
                if len(requests) == 1:
                    result["analysis"] = ""  # one existing bounded repair
                return {"usage": {"inputTokens": 100, "outputTokens": 50}, "stopReason": "end_turn",
                        "output": {"message": {"content": [{"text": json.dumps(result)}]}}}
        with tempfile.TemporaryDirectory() as directory:
            env = {"BEDROCK_SCAN_CALL_POLICY": "workload", "BEDROCK_SCAN_MAX_CALLS": "30",
                   "BEDROCK_SCAN_USAGE_FILE": str(Path(directory) / "usage.jsonl"),
                   "GITHUB_REPOSITORY": "example/repo", "GITHUB_RUN_ID": "123",
                   "BEDROCK_SCAN_PROFILES": json.dumps({
                       alias: f"arn:aws:bedrock:us-east-1:123456789012:application-inference-profile/{alias}"
                       for alias in ("sonnet", "opus", "sol")})}
            paid = BedrockCalls(None, 1, "123-1", None, context.prefix(), env,
                                client=Native(), fallback_factory=Backup)
            scanner = Scanner(context, files, None, paid, lambda value: progress.append(copy.deepcopy(value)), "b" * 40)
            scanner.use_cache = False
            result = scanner.run()  # automatic path selection, no force_deep
        self.assertEqual(paid.fallback.calls, [])
        return result, requests, progress, len(scanner.source)

    def test_large_automatic_scan_finishes_all_depth_hierarchical_integration_and_one_repair(self):
        # Real source segmentation yields 31 batches: the old 30-call CI limit
        # could not finish even the source pass. Long valid analyses also force
        # two integration levels for each model that integrates.
        result, requests, progress, source_batches = self.large_scan(1900)
        self.assertEqual(source_batches, 31)
        self.assertTrue(clean({"head": "a" * 40, "base": "b" * 40, "review": result}, "a" * 40, "b" * 40))
        self.assertTrue(result["finished"])
        self.assertTrue(progress[-1]["finished"])
        self.assertEqual(result["covered_units"], 63)
        self.assertEqual(result["depth_batches_pending"], 0)
        self.assertEqual(result["bedrock_planned_calls"], 99)
        self.assertEqual(result["bedrock_requests"], 100)
        self.assertEqual(result["bedrock_call_limit"], 100)
        self.assertEqual(result["response_repairs"][0]["status"], "completed")
        for alias, source_count, integration_count in (("sonnet", 32, 3), ("opus", 31, 0), ("sol", 31, 3)):
            self.assertEqual(requests.count((alias, "source")), source_count)
            self.assertEqual(requests.count((alias, "integration")), integration_count)

    def test_larger_workload_completes_beyond_the_previous_hundred_call_ceiling(self):
        result, requests, progress, source_batches = self.large_scan(3800)
        self.assertEqual(source_batches, 62)
        self.assertTrue(clean({"head": "a" * 40, "base": "b" * 40, "review": result}, "a" * 40, "b" * 40))
        self.assertTrue(progress[-1]["finished"])
        self.assertEqual(result["covered_units"], 124)
        self.assertEqual(result["depth_batches_pending"], 0)
        self.assertEqual(result["bedrock_planned_calls"], 196)
        self.assertEqual(result["bedrock_requests"], 197)
        self.assertEqual(result["bedrock_call_limit"], 197)
        self.assertEqual(result["bedrock_call_ceiling"], 500)
        for alias, source_count, integration_count in (("sonnet", 63, 5), ("opus", 62, 0), ("sol", 62, 5)):
            self.assertEqual(requests.count((alias, "source")), source_count)
            self.assertEqual(requests.count((alias, "integration")), integration_count)


class PolicyTests(unittest.TestCase):
    def setUp(self):
        self.head, self.base = "a" * 40, "b" * 40
        self.report = {"head": self.head, "base": self.base, "review": {
            "integration_completed": True, "covered_units": 3, "total_units": 3,
            "depth_batches_pending": 0, "findings": [], "errors": [], "limited_files": [],
            "manual_review_reasons": []}}
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

    def test_human_decision_is_not_reported_as_an_execution_failure(self):
        self.report["review"]["manual_review_reasons"] = ["Independent human review required"]
        body = status_body("example/repo", self.head, self.base, self.base, self.report["review"], {})
        self.assertIn("Scan completed; human review required", body)
        self.assertNotIn("Review not completed", body)
        self.assertFalse(clean(self.report, self.head, self.base))

    def test_final_incomplete_results_always_explicitly_require_a_human(self):
        for changes in ({"errors": ["Provider failed"]}, {"covered_units": 2},
                        {"integration_completed": False}, {"depth_batches_pending": 1},
                        {"limited_files": ["libs/runtime"]}):
            with self.subTest(changes=changes):
                snapshot = dict(self.report["review"], finished=True, **changes)
                body = status_body("example/repo", self.head, self.base, self.base, snapshot, {})
                self.assertIn("Human review required: CI did not complete", body)
                self.assertIn("do not manually rerun the paid scan", body)
                self.assertNotIn("**Scan completed.**", body)
                self.assertFalse(clean({"head": self.head, "base": self.base, "review": snapshot},
                                       self.head, self.base))

    def test_running_scan_is_not_prematurely_handed_to_a_human(self):
        snapshot = dict(self.report["review"], finished=False, integration_completed=False)
        body = status_body("example/repo", self.head, self.base, self.base, snapshot, {})
        self.assertIn("Review in progress", body)
        self.assertNotIn("Human review required: CI did not complete", body)

    def test_clearance_footer_preserves_human_decision_and_diagnostics(self):
        self.report["review"]["manual_review_reasons"] = ["Independent human review required"]
        self.report["review"]["diagnostics"] = [{"code": "RESPONSE_JSON_INVALID"}]
        body = status_body("example/repo", self.head, self.base, self.base,
                           self.report["review"], {}, clearance=True)
        self.assertIn("Scan completed; human review required", body)
        self.assertIn("RESPONSE_JSON_INVALID", body)
        self.assertIn("Merge clearance requires", body)

    def test_legacy_report_cannot_bypass_final_review_decision(self):
        del self.report["review"]["manual_review_reasons"]
        self.assertFalse(clean(self.report, self.head, self.base))

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
        self.report_path = report
        event.write_text(json.dumps({"pull_request": self.pull}))
        report.write_text(json.dumps({"repository": "Layr-Labs/d-inference", "run": "123-1", "head": self.head,
          "base": self.base, "diff_base": self.base, "review": {"integration_completed": True,
          "covered_units": 1, "total_units": 1, "depth_batches_pending": 0,
          "findings": [], "errors": [], "limited_files": [], "manual_review_reasons": []}}))
        self.env = {"THREAT_REVIEW_REQUIRE_CLEARANCE": "true", "GITHUB_EVENT_PATH": str(event),
                    "THREAT_REVIEW_RESULT_FILE": str(report), "GITHUB_REPOSITORY": "Layr-Labs/d-inference",
                    "GITHUB_RUN_ID": "123",
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

    def test_stale_or_unattributed_result_cannot_clear_matching_head_and_base(self):
        report = json.loads(self.report_path.read_text())
        for run in (None, "999-1", "123-2"):
            with self.subTest(run=run):
                stale = dict(report, run=run)
                if run is None:
                    del stale["run"]
                self.report_path.write_text(json.dumps(stale))
                self.assertEqual(self.evaluate(), 1)
        self.assertEqual(self.lookups, 0)

    def test_rerun_requires_this_attempts_result(self):
        self.env["GITHUB_RUN_ATTEMPT"] = "2"
        self.assertEqual(self.evaluate(), 1)
        report = json.loads(self.report_path.read_text())
        report["run"] = "123-2"
        self.report_path.write_text(json.dumps(report))
        self.assertEqual(self.evaluate(), 0)

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
