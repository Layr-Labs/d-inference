#!/usr/bin/env python3
"""Compare the existing connected e2e report's paired cache-off/default-SSD runs."""
import argparse
import json
from pathlib import Path


def terminal_usage(row):
    terminals = [event for event in row.get("wire", []) if event["type"] == "inference_complete"]
    if len(terminals) != 1:
        raise ValueError("one native terminal with actual usage required")
    return terminals[0]["fields"]["usage"]


def compare(baseline, candidate):
    errors = []
    for name, report in [("baseline", baseline), ("candidate", candidate)]:
        if report.get("schema") != 1 or report.get("state") != "completed" or report.get("wire_dropped") != 0:
            errors.append(f"{name}: incomplete/failed/truncated evidence")
    left, right = baseline["input"], candidate["input"]
    required = ["artifact", "catalog", "provider_sha256", "metallib_sha256", "sidecar_sha256",
                "backend", "mtp_mode", "max_concurrent", "tools_request", "prompt"]
    for name, values in [("baseline", left), ("candidate", right)]:
        for key in required:
            if not values.get(key):
                errors.append(f"{name}: required exact input absent: {key}")
    if (left["cache_mode"], right["cache_mode"]) != ("off", "ssd"):
        errors.append("expected cache-off baseline → default SSD candidate")
    # Paths may differ between owned packages, bytes/contracts may not.
    for key in ["artifact", "catalog", "provider_sha256", "metallib_sha256", "sidecar_sha256",
                "backend", "mtp_mode", "max_concurrent", "tools_request", "prompt", "vision_sha256"]:
        if left.get(key) != right.get(key):
            errors.append(f"input differs: {key}")
    arows, brows = baseline["cases"], candidate["cases"]
    if [row["name"] for row in arows] != [row["name"] for row in brows] or len(arows) != 10:
        errors.append("ten identical ordered case names required")
        return errors
    for a, b in zip(arows, brows):
        label = a["name"]
        if a["status"] == b["status"] == "not_applicable" and label == "vision":
            continue
        if a["status"] != "passed" or b["status"] != "passed":
            errors.append(f"{label}: both cells must pass")
            continue
        for key in ["request", "request_date_utc", "tenant_index"]:
            if a.get(key) != b.get(key) or (key == "request_date_utc" and not a.get(key)):
                errors.append(f"{label}: paired {key} differs/is absent")
        # Cancellation partial lengths depend on transport timing. Both gates
        # still require received/aborted proof and actual restored SSD usage.
        if label == "cancel":
            continue
        for key in ["content", "reasoning", "finish_reason"]:
            if a["http"].get(key) != b["http"].get(key):
                errors.append(f"{label}: served {key} differs")
        def calls(row):
            return sorted((str(index), call["name"], json.loads(call["arguments"]))
                          for index, call in row["http"].get("tools", {}).items())
        try:
            if calls(a) != calls(b):
                errors.append(f"{label}: decoded tool call differs")
            au, bu = terminal_usage(a), terminal_usage(b)
            for key in ["prompt_tokens", "completion_tokens", "reasoning_tokens"]:
                if au.get(key, 0) != bu.get(key, 0):
                    errors.append(f"{label}: native {key} differs")
            for row in [a, b]:
                if not row["http"].get("done") or not row["http"].get("finish_reason"):
                    errors.append(f"{label}: missing HTTP terminal")
                hu, nu = row["http"].get("usage"), terminal_usage(row)
                if not isinstance(hu, dict) or any(hu.get(key) != nu.get(key) for key in ["prompt_tokens", "completion_tokens"]):
                    errors.append(f"{label}: HTTP/native usage mismatch or absent usage")
        except (KeyError, ValueError, TypeError) as exc:
            errors.append(f"{label}: invalid retained output/usage: {exc}")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--output", required=True)
    args = parser.parse_args()
    errors = compare(json.loads(Path(args.baseline).read_text()), json.loads(Path(args.candidate).read_text()))
    result = {"passed": not errors, "errors": errors,
              "scope": "same-binary connected HTTP cache pair; no independent-machine or signed-restart claim"}
    Path(args.output).write_text(json.dumps(result, indent=2) + "\n")
    raise SystemExit(bool(errors))


if __name__ == "__main__":
    main()
