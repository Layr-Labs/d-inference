#!/usr/bin/env python3
"""Bounded synthetic source/integration checks for each configured Bedrock model."""
import os
import signal
from threat_review.bedrock import BedrockCalls, MODELS
from threat_review.client import ScanTimeout
from threat_review.review import review


def expired(*args):
    raise ScanTimeout("Smoke test deadline")


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
            findings, _, limits = review(threat, files, "", model, calls)
            if findings or limits:
                raise ValueError("Synthetic harmless fixture did not complete cleanly")
            print(f"{model}: source and integration schema/coverage validation passed")
        if calls.calls != 6 or calls.unknown:
            raise ValueError("Unexpected usage completeness")
    except Exception:
        print("Bedrock smoke test failed; no fallback or automatic model retry was attempted.")
        raise SystemExit(1) from None
    finally:
        signal.alarm(0)
