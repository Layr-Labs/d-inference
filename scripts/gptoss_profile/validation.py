"""Fail closed on incomplete runs or incomparable timing populations."""

import math
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def positive(value):
    return isinstance(value, (int, float)) and math.isfinite(value) and value > 0


def validate(report, spec, manifest):
    require(spec.get("provenanceID") == manifest.get("provenanceID"), "Cell provenance differs from run manifest")
    cell = spec["cell"]
    iterations = spec["iterations"]
    backend = spec["backend"]
    if "workload" in manifest:
        require(manifest["workload"] == {key: spec[key] for key in ("iterations", "decodeTokens", "backend")},
                "Cell workload differs from run manifest")
    require(report.get("modelID") == manifest["modelID"], "Model ID differs from pinned model")
    require(Path(report.get("modelPath", "")).resolve() == Path(manifest["model"]["path"]).resolve(),
            "Resolved model path differs from pinned snapshot")
    kv = report.get("kvBackend", {})
    require(kv.get("selection") == backend, "Requested KV backend mismatch")
    require(kv.get("resolved") and all(r.split()[0] == backend and "fallback" not in r
                                       for r in kv["resolved"]), "Resolved KV backend mismatch")
    if cell["phase"] == "decode":
        require(report.get("schemaVersion", 0) >= 6, "Decode schema predates raw common-overlap timing")
        ordered = report.get("schemaVersion", 0) >= 7
        require(cell["batch"] == 1 or ordered,
                "Batched decode requires schema 7 ordered submissions for performance comparison")
        if ordered:
            require(report.get("decodeSubmissionOrder") == "row_index", "Decode submission order is unspecified")
        coverage = report.get("decodeCoverage", {})
        require(coverage.get("requestedBatchSizes") == [cell["batch"]], "Requested batch coverage mismatch")
        require(coverage.get("unmeasured") == [] and not report.get("decodeConstructionFailure"),
                "Decode cell is unmeasured or failed")
        samples = report.get("decode", [])
        require(len(samples) == iterations, "Missing or extra decode repetitions")
        for sample in samples:
            require(sample.get("batchSize") == cell["batch"], "Batch size mismatch")
            require(sample.get("decodeTokensPerSequence") == spec["decodeTokens"], "Decode token request mismatch")
            require(sample.get("resolvedKVBackend", "").split()[0] == backend, "Per-sample KV mismatch")
            timing = sample.get("decodeTiming") or {}
            require(timing.get("decodePromptTokens") == cell["context"], "Decode context length mismatch")
            rows = timing.get("rows", [])
            require(len(rows) == cell["batch"], "Missing decode rows")
            require(sorted(r.get("row") for r in rows) == list(range(cell["batch"])), "Duplicate/missing row indices")
            if ordered:
                submitted = [r["submittedAtMs"] for r in sorted(rows, key=lambda r: r["row"])]
                require(submitted == sorted(submitted), "Decode submission timestamps contradict row order")
            for row in rows:
                require(row.get("finishReason") == "length", "Decode row did not terminate at the requested length")
                times, tokens = row.get("tokenArrivalMs", []), row.get("tokenIDs", [])
                require(len(times) == len(tokens) == spec["decodeTokens"] + 1,
                        "Decode row stopped early or emitted the wrong number of tokens")
                require(all(isinstance(t, (int, float)) and math.isfinite(t) for t in times)
                        and times == sorted(times), "Invalid token timestamps")
            require(positive(timing.get("overlapAggregateTokensPerSecond"))
                    and positive(timing.get("overlapDurationMs")), "No measurable common full-row decode window")
            counts = timing.get("overlapDecodedTokensPerRow", [])
            require(len(counts) == cell["batch"] and all(positive(n) for n in counts),
                    "A row made no progress in the common decode window")
            require(sum(counts) == timing.get("overlapDecodedTokens"), "Common-window token accounting mismatch")
            require(timing.get("overlapMeetsMinimumSupport") is True,
                    "Common full-row decode window has too few tokens; extend the generation")
            require(all(n >= 32 for n in counts), "Common window does not meet the minimum of 32 tokens per row")
            start = max(r["tokenArrivalMs"][0] for r in rows)
            end = min(r["tokenArrivalMs"][-1] for r in rows)
            recomputed = [sum(start < t <= end for t in r["tokenArrivalMs"][1:]) for r in rows]
            require(recomputed == counts and math.isclose(timing["overlapDurationMs"], end - start),
                    "Common-window summary disagrees with raw token timestamps")
            require(math.isclose(timing["overlapAggregateTokensPerSecond"], sum(counts) * 1000 / (end - start)),
                    "Common-window throughput disagrees with raw token timestamps")
    elif cell["phase"] == "prefill":
        require(report.get("schemaVersion", 0) >= 4, "Prefill schema predates full-shape warmup and memory evidence")
        samples = report.get("samples", [])
        require(report.get("promptLengths") == [cell["context"]], "Prefill prompt length mismatch")
        require(len(samples) == iterations, "Missing or extra prefill repetitions")
        require(all(s.get("promptTokens") == cell["context"] and positive(s.get("ttftMs"))
                    and s.get("resolvedKVBackend", "").split()[0] == backend for s in samples),
                "Invalid prefill sample")
    else:
        require(report.get("schemaVersion", 0) >= 5, "Arrival schema predates mixed prompt lengths")
        require(report.get("promptLengthsPerRequest") == [cell["context"], 512, 512, 512],
                "Arrival prompt lengths mismatch")
        patterns = report.get("patterns", [])
        require(bool(patterns), "No arrival patterns measured")
        for pattern in patterns:
            require(pattern.get("arrivalWithinTolerance") is True, "Arrival topology missed tolerance")
            require(pattern.get("outputsStableAcrossIterations") is True and pattern.get("outputsMatchBurst") is True,
                    "Arrival output invariance failed")
            samples = pattern.get("samples", [])
            require(len(samples) == iterations, "Missing arrival repetitions")
            require(all(len(s.get("rows", [])) == 4 for s in samples), "Arrival row coverage mismatch")
            for sample in samples:
                require(all(r.get("generatedTokens") == spec["decodeTokens"] for r in sample["rows"]),
                        "Arrival output token count mismatch")
    return report
