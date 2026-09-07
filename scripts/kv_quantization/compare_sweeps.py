#!/usr/bin/env python3
"""Summarize matched sweep observations without conflating prefill and decode."""

import argparse
import json
import statistics
from pathlib import Path


def read(path):
    return json.loads(path.read_text())


def runtime(path):
    result = read(path.with_suffix(".runtime.json"))
    if result.get("exitCode") != 0 or result.get("runtimeUnchanged") is not True:
        raise ValueError(f"Unsuccessful or changed runtime: {path}")
    return result["runtimeBeforeSHA256"]


def distribution(values):
    return {"mean": statistics.mean(values), "minimum": min(values), "maximum": max(values)}


def summarize(samples):
    if not samples:
        raise ValueError("No measured samples")
    for sample in samples:
        timing = sample["decodeTiming"]
        if not timing["overlapMeetsMinimumSupport"]:
            raise ValueError("Insufficient common-decode support")
        for row in timing["rows"]:
            if row.get("error") or row["finishReason"] != "length":
                raise ValueError("Invalid row terminal")
    timings = [sample["decodeTiming"] for sample in samples]
    return {
        "samples": len(samples),
        "overlap_aggregate_tokens_per_second": distribution(
            [timing["overlapAggregateTokensPerSecond"] for timing in timings]),
        "end_to_end_aggregate_tokens_per_second": distribution(
            [timing["endToEndTokensPerSecond"] for timing in timings]),
        "peak_mlx_bytes": distribution([timing["peakMemoryBytes"] for timing in timings]),
        "maximum_ttft_ms": max(row["tokenArrivalMs"][0] - row["submittedAtMs"]
                               for timing in timings for row in timing["rows"]),
        "maximum_inter_token_gap_ms": max(right - left for timing in timings
            for row in timing["rows"]
            for left, right in zip(row["tokenArrivalMs"], row["tokenArrivalMs"][1:])),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    native, candidate = read(args.native), read(args.candidate)
    for key in ("schemaVersion", "artifactIdentity", "hardware", "modelID", "modelPath",
                "gemmaOptimizations", "decodeSubmissionOrder", "decodeCoverage"):
        if key not in native or native[key] != candidate.get(key):
            raise ValueError(f"Control differs or is absent: {key}")
    if native["decodeCoverage"]["unmeasured"]:
        raise ValueError("Requested cells are unmeasured")
    if runtime(args.native) != runtime(args.candidate):
        raise ValueError("Runtime/config identities differ")
    if native["kvBackend"]["quantizationSelection"] != "native":
        raise ValueError("Native control required")
    if candidate["kvBackend"]["quantizationSelection"] == "native":
        raise ValueError("Packed candidate required")
    for report in (native, candidate):
        if report["kvBackend"]["selection"] != "paged":
            raise ValueError("Explicit paged execution required")
    rows = []
    for batch in native["decodeCoverage"]["requestedBatchSizes"]:
        arms = [[sample for sample in report["decode"] if sample["batchSize"] == batch]
                for report in (native, candidate)]
        controls = [[(sample["decodeTiming"]["decodePromptTokens"], sample["decodeTokensPerSequence"])
                     for sample in samples] for samples in arms]
        if controls[0] != controls[1]:
            raise ValueError("Prompt, output length or repetition count differs")
        rows.append({"batch_size": batch, "native": summarize(arms[0]),
                     "candidate": summarize(arms[1])})
    result = {"scope": "paired local observations; no significance or SLA qualification",
              "native_report": str(args.native), "candidate_report": str(args.candidate),
              "model_id": native["modelID"], "candidate_format": candidate["kvBackend"],
              "batches": rows}
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
