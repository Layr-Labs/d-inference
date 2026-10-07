#!/usr/bin/env python3
"""Bounded synthetic source/integration checks for each configured Bedrock model."""
import os
import signal
from threat_review.bedrock import BedrockCalls, MODELS
from threat_review.budget_scan import Scanner
from threat_review.client import ScanTimeout
from threat_review.context import ThreatContext


def expired(*args):
    raise ScanTimeout("Smoke test deadline")


def smoke_model(threat, files, model, calls):
    """Exercise the production schema and validators without state or escalation."""
    scanner = Scanner(ThreatContext(threat), files, None, calls, lambda _: None, "smoke")
    scanner.use_cache = False
    if scanner.limits or len(scanner.source) != 1:
        raise ValueError("Synthetic fixture must fit one complete source batch")
    result = scanner.call(model, "source", scanner.source[0])
    if result["findings"]:
        raise ValueError("Synthetic source did not complete cleanly")
    deeper = {"source": result["needs_deeper_review"]}
    result = scanner.integrate(model, [{"id": "0", "analysis": result["analysis"],
                                       "findings": result["findings"]}])
    if result["findings"]:
        raise ValueError("Synthetic integration did not complete cleanly")
    return dict(deeper, integration=result["needs_deeper_review"])


if __name__ == "__main__":
    signal.signal(signal.SIGALRM, expired)
    signal.alarm(10 * 60)
    env = dict(os.environ, BEDROCK_SCAN_MAX_CALLS="6", BEDROCK_SCAN_MAX_OUTPUT_TOKENS="4096",
               BEDROCK_SCAN_CREDENTIALS_READY="true")
    # No key: a failed Bedrock smoke test cannot succeed by falling back.
    calls = BedrockCalls(None, 0, env["GITHUB_RUN_ID"], "", "Synthetic model compatibility test", env)
    files = [{"filename": "smoke.py", "status": "modified", "additions": 1, "deletions": 1,
              "patch": "@@ -1 +1 @@\n-answer = 40 + 2\n+answer = 42",
              "base_text": "answer = 40 + 2\n", "head_text": "answer = 42\n"}]
    threat = "threats:\n  - id: T-SMOKE\n    description: Preserve the integer answer and do not add I/O.\n"
    try:
        for model in MODELS:
            deeper = smoke_model(threat, files, model, calls)
            print(f"{model}: source and integration schema/coverage validation passed; "
                  f"needs_deeper_review={deeper}; compatibility only, not security clearance")
        if calls.calls != 6 or calls.unknown:
            raise ValueError("Unexpected usage completeness")
    except Exception:
        print("Bedrock smoke test failed; no fallback or automatic model retry was attempted.")
        raise SystemExit(1) from None
    finally:
        signal.alarm(0)
