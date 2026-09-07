#!/usr/bin/env python3
"""Compare same-build native/packed authored generation observations."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    native = json.loads(args.native.read_text())
    candidate = json.loads(args.candidate.read_text())
    required_same = ["schema", "scope", "input", "inputSHA256", "beforeModelAggregateSHA256",
                     "afterModelAggregateSHA256", "executableSHA256", "metallibSHA256",
                     "modelDirectory", "resolvedBackend", "stopTokenIDs", "temperature",
                     "seed", "cacheMode", "mtpEnabled", "concurrency"]
    for key in required_same:
        if native.get(key) != candidate.get(key) or key not in native:
            raise ValueError(f"Mismatched or absent control: {key}")
    if native.get("kvQuantizationIdentity") is not None or not candidate.get("kvQuantizationIdentity"):
        raise ValueError("Comparison requires native control and explicit packed candidate")
    if native["scope"] != "bounded_free_generation_observations":
        raise ValueError("Unknown quality observation scope")
    serving = "servingParserFormat" in native or "servingParserFormat" in candidate
    if serving:
        for key in ("declaredModelType", "servingParserFormat", "servingExpectedTextMatchSource"):
            if native.get(key) != candidate.get(key):
                raise ValueError(f"Serving parser control differs: {key}")
    if len(native["cases"]) != len(candidate["cases"]):
        raise ValueError("Case coverage differs")
    rows = []
    for left, right in zip(native["cases"], candidate["cases"]):
        for key in ("name", "index", "requestID", "promptTokenCount", "maximumTokens"):
            if left[key] != right[key]:
                raise ValueError(f"Case identity differs: {key}")
        row = {"name": left["name"], "prompt_tokens": left["promptTokenCount"],
                     "native_issues": left["issues"], "candidate_issues": right["issues"],
                     "native_error": left.get("error"), "candidate_error": right.get("error"),
                     "native_finish": left.get("finishReason"), "candidate_finish": right.get("finishReason"),
                     "native_expected_match": left.get("expectedOuterWhitespaceMatch"),
                     "candidate_expected_match": right.get("expectedOuterWhitespaceMatch"),
                     "same_tokens": left["generatedTokenIDs"] == right["generatedTokenIDs"],
                     "same_streamed_text": left["streamedText"] == right["streamedText"],
                     "native_text": left["streamedText"], "candidate_text": right["streamedText"],
                     "native_first_token_ms": left.get("firstTokenMs"),
                     "candidate_first_token_ms": right.get("firstTokenMs")}
        if serving:
            row.update(native_serving_text=left["servingContent"],
                       candidate_serving_text=right["servingContent"],
                       native_serving_expected_match=left.get("servingExpectedOuterWhitespaceMatch"),
                       candidate_serving_expected_match=right.get("servingExpectedOuterWhitespaceMatch"))
        rows.append(row)
    result = {"scope": "paired authored regression probes; not broad quality qualification",
              "native_report": str(args.native), "candidate_report": str(args.candidate),
              "native_status": native["status"], "candidate_status": candidate["status"],
              "model_id": native["input"]["modelID"], "concurrency": native["concurrency"],
              "candidate_format": candidate["kvQuantizationIdentity"],
              "graded_cases": sum(row["native_expected_match"] is not None for row in rows),
              "native_expected_matches": sum(row["native_expected_match"] is True for row in rows),
              "candidate_expected_matches": sum(row["candidate_expected_match"] is True for row in rows),
              "same_text_cases": sum(row["same_streamed_text"] for row in rows),
              "cases": rows}
    if serving:
        result.update(serving_parser=native["servingParserFormat"],
                      native_serving_expected_matches=sum(row["native_serving_expected_match"] is True for row in rows),
                      candidate_serving_expected_matches=sum(row["candidate_serving_expected_match"] is True for row in rows))
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "cases"}))


if __name__ == "__main__":
    main()
