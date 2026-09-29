"""Summarize supervised production-path receipts without claiming promotion."""
from .calibration_statistics import percentile
from .token_timings import measure


def summarize(report):
    cells = []
    for trial in report.get("trials", []):
        rates, first_content, gaps, failures = [], [], [], []
        for row in trial["rows"]:
            arrivals = row.get("contentArrivalMs", [])
            gaps.extend(b - a for a, b in zip(arrivals, arrivals[1:]))
            if row.get("firstContentMs") is not None:
                first_content.append(row["firstContentMs"])
            profile = row.get("profile", {})
            # Delivered throughput ends at the last content frame, excludes
            # prompt/terminal time, and is explicitly distinct from engine TPS.
            if len(arrivals) >= 2 and arrivals[-1] > arrivals[0] and row["completionTokens"] > 1:
                rates.append((row["completionTokens"] - 1) * 1000 / (arrivals[-1] - arrivals[0]))
            if row.get("failure"):
                failures.append(row["failure"])
            if report["job"]["reused"] and row.get("cachedTokens", 0) <= 0:
                failures.append("requested_reuse_not_observed")
            if not profile.get("engine"):
                failures.append("engine_timing_missing")
        shapes = trial["forwardShapes"]
        engine_rates, token_gaps, observation_failures = measure(shapes, len(trial["rows"]),
            sum(row["completionTokens"] for row in trial["rows"]))
        failures.extend(observation_failures)
        steps = shapes.get("completedStepTimings", [])
        mixed = [s["wallNanos"] / 1e6 for s in steps if s["phase"] == "mixed_prefill_decode"]
        target_widths = sorted({entry["axes"]["liveBatchRows"] for entry in shapes["entries"]
                                if entry["axes"]["kind"] == "target" and entry["completedCalls"] > 0})
        if (shapes.get("droppedStepTimings") != 0 or shapes.get("droppedCalls", 0) or
                shapes.get("pendingSteps", 0) or shapes.get("unobservedDispatches", 0)):
            failures.append("incomplete_step_observation")
        if not trial["retired"]:
            failures.append("retirement_not_confirmed")
        if not trial["mtpActive"] or trial["mtpRounds"] <= 0 or trial["mtpProposed"] <= 0:
            failures.append("actual_mtp_not_observed")
        cells.append({"prompt_target": trial["promptTarget"], "iteration": trial["iteration"],
                      "actual_prompt_tokens": [r["promptTokens"] for r in trial["rows"]],
                      "delivered_decode_p10_tps": percentile(rates, .1) if rates else None,
                      "engine_decode_p10_tps": percentile(engine_rates, .1) if engine_rates else None,
                      "engine_token_gap_p95_ms": percentile(token_gaps, .95) if token_gaps else None,
                      "first_content_p50_ms": percentile(first_content, .5) if first_content else None,
                      "first_content_p95_ms": percentile(first_content, .95) if first_content else None,
                      "content_frame_gap_p95_ms": percentile(gaps, .95) if gaps else None,
                      "mixed_step_wall_p95_ms": percentile(mixed, .95) if mixed else None,
                      "mixed_step_count": len(mixed), "actual_forward_widths": target_widths,
                      "mtp_rounds": trial["mtpRounds"], "failures": sorted(set(failures))})
    return {"qualified": False, "complete": report.get("complete", False), "cells": cells,
            "promotion_blockers": ["collection is not the complete release matrix",
                                   "independent calibration/validation receipts required"]}
