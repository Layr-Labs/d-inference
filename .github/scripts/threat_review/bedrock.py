"""Attributed Bedrock Converse calls; explicit fallback, never result resampling.

Adapted from Layr-Labs/bedrock-codescan-template at
0abf9843a583d93fb6f9c04ecbb1a0c4425bc117; see bedrock-upstream-LICENSE.
"""
import json
import re
from datetime import datetime, timezone
from pathlib import Path

from .client import ReviewUnavailable, ScanTimeout
from .context import SONNET, OPUS, SOL
from .paid import PaidCalls
from .state import BudgetStopped

MODELS = {SONNET: "sonnet", OPUS: "opus", SOL: "sol"}
PROFILE = re.compile(r"arn:aws:bedrock:[a-z0-9-]+:\d{12}:application-inference-profile/[A-Za-z0-9]+")
# These responses explicitly decline the request. Timeouts, unknown failures,
# invalid JSON and model refusals do not authorize another provider invocation.
UNAVAILABLE = {"ThrottlingException", "ModelNotReadyException", "ServiceQuotaExceededException",
               "AccessDeniedException", "ResourceNotFoundException", "ServiceUnavailableException"}


def bounded(env, name, default, low, high):
    try:
        value = int(env.get(name) or default)
    except (TypeError, ValueError):
        raise ReviewUnavailable(f"Invalid {name}") from None
    if not low <= value <= high:
        raise ReviewUnavailable(f"Invalid {name}")
    return value


class BedrockCalls:
    def __init__(self, state, pr, run, key, prefix, env, alive=lambda: None,
                 client=None, fallback_factory=PaidCalls):
        self.key, self.env, self.alive, self.prefix = key, env, alive, prefix
        self.fallback = fallback_factory(state, pr, run, key, prefix, alive=alive)
        self.profiles = json.loads(env.get("BEDROCK_SCAN_PROFILES") or "{}")
        if (not isinstance(self.profiles, dict) or set(self.profiles) != set(MODELS.values())
                or any(not isinstance(p, str) or not PROFILE.fullmatch(p) for p in self.profiles.values())):
            raise ReviewUnavailable("Configure one application inference profile per review model")
        self.limit = bounded(env, "BEDROCK_SCAN_MAX_CALLS", 12, 1, 100)
        self.output_tokens = bounded(env, "BEDROCK_SCAN_MAX_OUTPUT_TOKENS", 4096, 256, 16384)
        self.calls = self.fallbacks = self.input_tokens = self.output_used = 0
        self.unknown = 0
        self.ledger = Path(env["BEDROCK_SCAN_USAGE_FILE"])
        self.ledger.parent.mkdir(parents=True, exist_ok=True)
        self.client = client

    @property
    def stopped(self):
        return self.fallback.stopped

    def record(self, **fields):
        entry = {"run": self.env["GITHUB_RUN_ID"], "attempt": self.env.get("GITHUB_RUN_ATTEMPT", "1"),
                 "repository": self.env["GITHUB_REPOSITORY"], "call": self.calls,
                 "timestamp": datetime.now(timezone.utc).isoformat(), **fields}
        with self.ledger.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(entry, sort_keys=True) + "\n")
            stream.flush()

    def backup(self, endpoint, key, payload, reason):
        self.alive()
        if not self.key:
            raise ReviewUnavailable("Bedrock unavailable and OpenRouter backup is not configured")
        self.record(event="fallback", model=payload["model"], reason=reason)
        self.fallbacks += 1
        # This path retains the existing durable dollar reservations and pilot
        # caps. AWS token usage is never reported as OpenRouter dollar charges.
        return self.fallback(endpoint, key, payload)

    def __call__(self, endpoint, key, payload):
        self.alive()
        if self.calls >= self.limit:
            raise BudgetStopped("Bedrock request allowance reached; no fallback around the limit")
        alias = MODELS[payload["model"]]
        if self.env.get("BEDROCK_SCAN_CREDENTIALS_READY") != "true" and self.client is None:
            return self.backup(endpoint, key, payload, "credentials unavailable")
        if self.client is None:
            import boto3
            from botocore.config import Config
            self.client = boto3.client("bedrock-runtime", region_name=self.env.get("BEDROCK_SCAN_AWS_REGION", "us-east-1"),
                                       config=Config(connect_timeout=10, read_timeout=240,
                                                     retries={"total_max_attempts": 1, "mode": "standard"}))
        system = payload["messages"][0]["content"] + "\n" + self.prefix
        schema = payload["response_format"]["json_schema"]["schema"]
        request = {"modelId": self.profiles[alias],
                   "system": [{"text": system + "\nReturn only JSON matching this schema:\n" + json.dumps(schema)}],
                   "messages": [{"role": "user", "content": [{"text": payload["messages"][1]["content"]}]}],
                   "inferenceConfig": {"maxTokens": self.output_tokens},
                   "requestMetadata": {"repository": self.env["GITHUB_REPOSITORY"],
                                       "run": self.env["GITHUB_RUN_ID"], "model": alias}}
        if len(json.dumps(request, ensure_ascii=False).encode()) > 180_000:
            raise BudgetStopped("Bedrock request exceeds conservative context bound")
        # Prompt schema plus the scanner's strict validator works uniformly;
        # native structured output is not assumed to work for every model.
        self.calls += 1
        self.record(event="attempt", model=alias, profile=self.profiles[alias])
        self.unknown += 1
        try:
            response = self.client.converse(**request)
        except ScanTimeout:
            self.record(event="error", model=alias, usage_unknown=True)
            raise
        except Exception as error:
            detail = getattr(error, "response", {})
            code = detail.get("Error", {}).get("Code") if isinstance(detail, dict) else None
            safe = code if code in UNAVAILABLE else "RequestFailure"
            self.record(event="error", model=alias, reason=safe, usage_unknown=True)
            if code in UNAVAILABLE:
                return self.backup(endpoint, key, payload, safe)
            raise ReviewUnavailable("Bedrock request failed with uncertain outcome; no automatic fallback") from None
        usage = response.get("usage", {})
        incoming, outgoing = usage.get("inputTokens"), usage.get("outputTokens")
        known = all(type(v) is int and v >= 0 for v in (incoming, outgoing))
        self.record(event="response", model=alias, usage_unknown=not known,
                    input_tokens=incoming if known else None, output_tokens=outgoing if known else None)
        if not known:
            raise ReviewUnavailable("Bedrock usage missing; no complete result")
        self.unknown -= 1
        self.input_tokens += incoming
        self.output_used += outgoing
        if response.get("stopReason") != "end_turn":
            raise ReviewUnavailable("Bedrock response incomplete or refused; no automatic fallback")
        text = "".join(b["text"] for b in response["output"]["message"]["content"] if "text" in b)
        fenced = re.fullmatch(r"\s*```json\r?\n(.*)\r?\n```\s*", text, re.S)
        if fenced:
            text = fenced.group(1)
        return {"choices": [{"finish_reason": "stop", "message": {"content": text}}]}

    def metrics(self):
        return {**self.fallback.metrics(), "bedrock_requests": self.calls,
                "bedrock_unknown_usage": self.unknown, "bedrock_input_tokens": self.input_tokens,
                "bedrock_output_tokens": self.output_used, "openrouter_fallbacks": self.fallbacks}
