#!/usr/bin/env python3
"""Compare hash-matched native/quantized teacher-forced diagnostic reports.

Emits observations only; no automatic quality or release verdict.
"""

import argparse
import json
import math
from pathlib import Path
import struct


def float32(bits):
    return struct.unpack("!f", struct.pack("!I", bits))[0]


def summary(report):
    records = report["diagnostic"]["records"]
    nll = [float32(record["nllBits"]) for record in records]
    if not nll or not all(math.isfinite(value) for value in nll):
        raise ValueError("Report contains empty or nonfinite scoring data")
    if report["status"] != "observed" or report["inconclusiveReasons"]:
        raise ValueError("Report's own repeated numerical controls are inconclusive")
    mean = sum(nll) / len(nll)
    return {"tokens": len(nll), "mean_forced_token_nll": mean,
            "continuation_perplexity": math.exp(mean) if mean < 700 else None,
            "format": report["kvQuantization"],
            "format_identity": report.get("kvQuantizationIdentity")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    reference = json.loads(args.reference.read_text())
    candidate = json.loads(args.candidate.read_text())
    for field in ["scope", "inputSHA256", "verifiedModelAggregateSHA256",
                  "executableSHA256", "metallibSHA256", "modelDirectory", "resolvedBackend"]:
        if reference[field] != candidate[field]:
            raise ValueError(f"Comparison identity mismatch: {field}")
    if reference["input"] != candidate["input"]:
        raise ValueError("Exact token contexts differ")
    left, right = summary(reference), summary(candidate)
    if left["format"] != "native" or left["tokens"] != right["tokens"]:
        raise ValueError("Expected native reference with equal scoring coverage")
    count = left["tokens"]
    left_records = reference["diagnostic"]["records"]
    right_records = candidate["diagnostic"]["records"]
    deltas = [float32(b["nllBits"]) - float32(a["nllBits"])
              for a, b in zip(left_records, right_records)]
    result = {"scope": "paired exact-context diagnostic; not quality qualification",
              "reference": str(args.reference), "candidate": str(args.candidate),
              "reference_summary": left, "candidate_summary": right,
              "mean_nll_delta": right["mean_forced_token_nll"] - left["mean_forced_token_nll"],
              "max_token_nll_increase": max(deltas),
              "top1_agreement": sum(a["argMaxID"] == b["argMaxID"]
                                    for a, b in zip(left_records, right_records)) / count,
              "input_sha256": reference["inputSHA256"],
              "model_aggregate": reference["verifiedModelAggregateSHA256"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
