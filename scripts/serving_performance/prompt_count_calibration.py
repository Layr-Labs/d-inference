"""Join real provider counts with the canonical Go estimator/shape projection."""
import hashlib
import json
import math

from .calibration_statistics import coverage_lower_bound, fit_upper_bound, percentile
from .matrix import digest

SHAPE_FIELDS = ("body_bytes", "message_count", "message_bytes", "system_message_count",
                "developer_message_count", "assistant_message_count", "tool_definition_count",
                "tool_definition_bytes", "tool_call_count", "tool_call_bytes",
                "tool_result_count", "tool_result_bytes")


def evaluate_prompt_counts(provider_raw, coordinator_raw):
    provider = json.loads(provider_raw)
    projections = [json.loads(line) for line in coordinator_raw.splitlines() if line.strip()]
    by_hash = {row["workload_sha256"]: row for row in projections}
    combined_hash = hashlib.sha256(provider_raw + b"\n" + coordinator_raw).hexdigest()
    result = {"qualified": False, "report_sha256": combined_hash, "cells": [], "errors": []}
    for field in ("artifactSHA256", "promptContractID"):
        if not digest(provider.get(field)):
            result["errors"].append(f"missing exact {field}")
    if len(by_hash) != len(projections):
        result["errors"].append("duplicate projected workload hash")
    observations = provider.get("observations", [])
    groups, seen = {}, set()
    for observed in observations:
        work_hash = observed.get("workloadSHA256")
        if work_hash in seen:
            result["errors"].append("duplicate workload cannot count as independent evidence")
        seen.add(work_hash)
        projection = by_hash.get(work_hash)
        if projection is None:
            result["errors"].append("provider observation lacks canonical Go projection")
            continue
        # Corpus IDs freeze the tools/estimate-band groups before collection.
        parts = observed.get("id", "").split("-")
        if len(parts) != 4 or parts[1] not in ("tools0", "tools1") or parts[2] not in ("band0", "band1", "band2"):
            result["errors"].append("observation lacks predeclared corpus group")
            continue
        group = (parts[1], parts[2])
        groups.setdefault(group, []).append((observed, projection))
    if seen != set(by_hash):
        result["errors"].append("count and shape receipt populations do not match")
    for key, rows in sorted(groups.items()):
        errors = []
        training = [(o, p) for o, p in rows if o.get("partition") == "calibration"]
        validation = [(o, p) for o, p in rows if o.get("partition") == "validation"]
        if len(training) < 20 or len(validation) < 59 or len(training) + len(validation) != len(rows):
            errors.append("requires 20 training and 59 independent validation observations")
        if any(o.get("failure") or type(o.get("actualPromptTokens")) is not int or o["actualPromptTokens"] <= 0
               or p.get("shape_known") is not True or type(p.get("estimated_tokens")) is not int or p["estimated_tokens"] <= 0
               or set(p.get("shape", {})) != set(SHAPE_FIELDS)
               or any(type(p["shape"].get(field)) is not int or p["shape"][field] < 0 for field in SHAPE_FIELDS)
               for o, p in rows):
            errors.append("failed/unknown observations cannot disappear from the cohort")
        if errors:
            result["cells"].append({"group": key, "qualified": False, "errors": errors})
            continue
        median = percentile([o["actualPromptTokens"] / p["estimated_tokens"] for o, p in training], .5)
        ratio, additive = fit_upper_bound([(p["estimated_tokens"], o["actualPromptTokens"]) for o, p in training], median)
        # The applicability domain is fitted on training inputs only. Holdout
        # requests outside it remain uncovered, rather than expanding it after
        # observing their outcomes or being removed from the denominator.
        domain = {name: {"min": min(p["shape"][name] for _, p in training),
                         "max": max(p["shape"][name] for _, p in training)} for name in training[0][1]["shape"]}
        min_estimate = min(p["estimated_tokens"] for _, p in training)
        max_estimate = max(p["estimated_tokens"] for _, p in training)
        def in_domain(projection):
            return min_estimate <= projection["estimated_tokens"] <= max_estimate and all(
                bounds["min"] <= projection["shape"].get(name, -1) <= bounds["max"] for name, bounds in domain.items())
        covered = sum(in_domain(p) and o["actualPromptTokens"] <= math.ceil(p["estimated_tokens"] * ratio + additive)
                      for o, p in validation)
        lower = coverage_lower_bound(covered, len(validation))
        if lower < .95:
            errors.append("held-out coverage confidence lower bound is below95percent")
        candidate = {"id": "prompt-count-" + combined_hash[:16] + "-" + "-".join(key), "model_id": provider["modelID"],
                     "model_artifact_hash": provider["artifactSHA256"], "prompt_contract_id": provider["promptContractID"],
                     "report_sha256": combined_hash, "min_estimated_tokens": min_estimate,
                     "max_estimated_tokens": max_estimate, "has_tools": key[0] == "tools1",
                     "shape_domain": domain, "median_ratio": median, "upper_ratio": ratio,
                     "upper_additive_tokens": additive, "training_samples": len(training),
                     "validation_samples": len(validation), "validation_covered": covered,
                     "tail_coverage_lower_bound": lower}
        result["cells"].append({"group": key, "qualified": not errors, "errors": errors, "candidate": candidate,
                                "validation_out_of_domain": sum(not in_domain(p) for _, p in validation),
                                "validation_upper_error_max_tokens": max(
                                    o["actualPromptTokens"] - math.ceil(p["estimated_tokens"] * ratio + additive) for o, p in validation)})
    result["qualified"] = not result["errors"] and any(cell["qualified"] for cell in result["cells"])
    return result
