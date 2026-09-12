"""Derive summaries from validated raw samples, retaining timing definitions."""

import csv
import json
import math
from pathlib import Path
from statistics import mean, median, stdev

from .provenance import digest, write_json
from .validation import validate
from .power import power_failure


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    index = (len(values) - 1) * fraction
    low, high = math.floor(index), math.ceil(index)
    return values[low] + (values[high] - values[low]) * (index - low)


def dispersion(values):
    center = median(values)
    return {"median": center, "minimum": min(values), "maximum": max(values),
            "medianAbsoluteDeviation": median([abs(v - center) for v in values]),
            "coefficientOfVariation": stdev(values) / mean(values) if len(values) > 1 and mean(values) else None}


def summarize_cell(report, spec):
    cell = spec["cell"]
    result = {**cell, "iterations": spec["iterations"],
              "decodeTokens": spec["decodeTokens"], "backend": spec["backend"]}
    if cell["phase"] == "decode":
        timings = [s["decodeTiming"] for s in report["decode"]]
        aggregates = [t["overlapAggregateTokensPerSecond"] for t in timings]
        intervals = [b - a for t in timings for row in t["rows"]
                     for a, b in zip(row["tokenArrivalMs"], row["tokenArrivalMs"][1:])]
        common_intervals = [b - a for t in timings for row in t["rows"]
                            for a, b in zip(row["tokenArrivalMs"], row["tokenArrivalMs"][1:])
                            if a >= max(r["tokenArrivalMs"][0] for r in t["rows"])
                            and b <= min(r["tokenArrivalMs"][-1] for r in t["rows"])]
        result.update({"aggregateDecodeTPS": median(aggregates),
                       "aggregateDecodeDistribution": dispersion(aggregates),
                       "perRequestDecodeTPS": median(aggregates) / cell["batch"],
                       "fairShareDecodeTPS": median(aggregates) / cell["batch"],
                       "perRowWholeDecodeTPS": [median([(len(t["rows"][i]["tokenArrivalMs"]) - 1) * 1000 /
                                                        (t["rows"][i]["tokenArrivalMs"][-1] - t["rows"][i]["tokenArrivalMs"][0])
                                                        for t in timings]) for i in range(cell["batch"])],
                       "perRowCommonWindowTPS": [median([t["overlapDecodedTokensPerRow"][i] * 1000 /
                                                        t["overlapDurationMs"] for t in timings])
                                                 for i in range(cell["batch"])],
                       "legacyWholeRowAggregateTPS": median([s["aggregateTokensPerSecond"] for s in report["decode"]]),
                       "endToEndTPS": median([t["endToEndTokensPerSecond"] for t in timings]),
                       "interTokenP50Ms": percentile(intervals, .5),
                       "interTokenP95Ms": percentile(intervals, .95),
                       "commonWindowInterTokenP50Ms": percentile(common_intervals, .5),
                       "commonWindowInterTokenP95Ms": percentile(common_intervals, .95),
                       "peakMemoryBytes": max(t["peakMemoryBytes"] for t in timings),
                       "commonWindowMinimumRowTokens": min(min(t["overlapDecodedTokensPerRow"]) for t in timings),
                       "ttftMedianMs": median([row["tokenArrivalMs"][0] - row["submittedAtMs"]
                                               for t in timings for row in t["rows"]])})
    elif cell["phase"] == "prefill":
        times = [s["ttftMs"] for s in report["samples"]]
        result.update({"ttftMedianMs": median(times), "ttftDistribution": dispersion(times),
                       "promptTokensPerSecond": median([cell["context"] * 1000 / t for t in times]),
                       "peakMemoryBytes": max(s["peakMemoryBytes"] for s in report["samples"]),
                       "soloPrefillStripeTokens": report.get("soloPrefillStripeTokens")})
    else:
        result["patterns"] = [{"name": p["name"], "ttftMedianMs": p["medianTTFTMs"],
                               "perRequestDecodeTPS": p["medianPerRequestDecodeTokensPerSecond"],
                               "arrivalAggregateDecodeTPS": p["medianAggregateDecodeTokensPerSecond"],
                               "makespanMedianMs": p["medianMakespanMs"],
                               "rowTTFTMedianMs": [median([s["rows"][i]["ttftMs"] for s in p["samples"]])
                                                   for i in range(4)]}
                              for p in report["patterns"]]
    return result


def summarize(directory):
    directory = Path(directory)
    manifest = json.loads((directory / "manifest.json").read_text())
    rows, failures = [], []
    for cell_dir in sorted((directory / "cells").glob("*")):
        try:
            spec = json.loads((cell_dir / "spec.json").read_text())
            process = json.loads((cell_dir / "process.json").read_text())
            if process.get("returncode") != 0 or process.get("timedOut") or process.get("interrupted") or process.get("powerRequirementFailed"):
                raise ValueError(f"Process failed: {process}")
            required = spec.get("requiredACPowerMode")
            if required != manifest.get("requiredACPowerMode"):
                raise ValueError("Cell power requirement differs from run manifest")
            if required is not None:
                for moment in ("before", "after"):
                    failure = power_failure(json.loads((cell_dir / f"host-{moment}.json").read_text()), required)
                    if failure:
                        raise ValueError(f"{moment} power invalid: {failure}")
            report = json.loads((cell_dir / "stdout.raw").read_text())
            if (cell_dir / "validation.json").exists():
                recorded = json.loads((cell_dir / "validation.json").read_text())
                if not recorded.get("valid"):
                    raise ValueError(recorded.get("error", "Run-time validation failed"))
                if recorded.get("rawSHA256") != digest(cell_dir / "stdout.raw"):
                    raise ValueError("Raw output changed after validation")
            validate(report, spec, manifest)
            row = summarize_cell(report, spec)
            row["rawSHA256"] = digest(cell_dir / "stdout.raw")
            rows.append(row)
        except (ValueError, KeyError, OSError, TypeError, IndexError) as error:
            failures.append({"cell": cell_dir.name, "error": str(error)})
    for row in rows:
        if row["phase"] == "decode":
            base = next((r for r in rows if r["phase"] == "decode" and r["context"] == row["context"]
                         and r["batch"] == 1
                         and all(r[key] == row[key] for key in ("iterations", "decodeTokens", "backend"))), None)
            row["scalingVsB1"] = row["aggregateDecodeTPS"] / base["aggregateDecodeTPS"] if base else None
            row["batchScalingEfficiency"] = row["scalingVsB1"] / row["batch"] if base else None
    result = {"schemaVersion": 1, "mode": manifest["mode"], "provenanceID": manifest["provenanceID"],
              "cells": rows, "failures": failures,
              "timingDefinition": "Decode headline counts events in the host-observed common window from the latest first token to the earliest last token. It establishes simultaneous row progress, not scheduler batch occupancy. TTFT includes generated reasoning tokens; it is not time to visible answer content.",
              "tailCaveat": "Inter-token percentiles pool correlated token intervals; five repetitions do not establish request-tail latency.",
              "perRequestDefinition": "fairShareDecodeTPS and the compatibility alias perRequestDecodeTPS equal aggregate/B. Actual row rates are in perRowCommonWindowTPS and perRowWholeDecodeTPS. interTokenP* includes all post-first-token intervals, potentially prefill interference; commonWindowInterTokenP* includes only intervals fully inside the shared window.",
              "warmupDefinition": "Full-context prefill and per-batch decode warmups run inside each fresh cell process before measured repetitions. Exact shape and start/completion markers are retained in cells/*/stderr.raw; warmup timings do not enter summaries.",
              "prefillDefinition": "Prompt tokens divided by production request TTFT, including first token and scheduler overhead; not an isolated GPU prefill timer.",
              "arrivalDefinition": "Mixed arrivals have unequal prompt lengths. Their aggregate is separate from the common-window steady decode headline."}
    write_json(directory / "summary.json", result)
    columns = ["name", "phase", "context", "batch", "iterations", "decodeTokens", "backend", "aggregateDecodeTPS", "fairShareDecodeTPS",
               "scalingVsB1", "batchScalingEfficiency", "ttftMedianMs", "promptTokensPerSecond", "interTokenP50Ms",
               "interTokenP95Ms", "commonWindowInterTokenP50Ms", "commonWindowInterTokenP95Ms", "peakMemoryBytes", "commonWindowMinimumRowTokens"]
    with (directory / "summary.csv").open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    def display(value):
        return "—" if value is None else f"{value:.2f}" if isinstance(value, float) else str(value)
    lines = [f"# GPT-OSS profile ({manifest['mode']})", "", result["timingDefinition"], "", result["tailCaveat"], "",
             "| Cell | Aggregate decode tok/s | Fair share (aggregate/B) | Scaling / B1 | TTFT ms | Peak GiB |",
             "|---|---:|---:|---:|---:|---:|"]
    for row in rows:
        lines.append("| " + " | ".join(display(v) for v in (row["name"], row.get("aggregateDecodeTPS"),
                     row.get("perRequestDecodeTPS"), row.get("scalingVsB1"), row.get("ttftMedianMs"),
                     row.get("peakMemoryBytes", 0) / 2**30 if "peakMemoryBytes" in row else None)) + " |")
        for pattern in row.get("patterns", []):
            lines.append(f"\n{row['name']} / {pattern['name']}: median row TTFT ms = {pattern['rowTTFTMedianMs']}; "
                         f"makespan {pattern['makespanMedianMs']:.2f} ms (arrival-specific aggregate in JSON).\n")
    lines += ["", result["perRequestDefinition"], "", result["warmupDefinition"], "", result["prefillDefinition"], "", result["arrivalDefinition"], "", f"Invalid/incomplete cells: {len(failures)}."]
    lines += [f"- {f['cell']}: {f['error']}" for f in failures]
    (directory / "summary.md").write_text("\n".join(lines) + "\n")
    return result
