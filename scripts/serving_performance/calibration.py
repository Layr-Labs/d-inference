"""Fit deadline error from calibration trials, then test independent holdout.

Receipts contain numeric workload/timing evidence only. Censored or refused
trials remain visible and cannot be silently discarded to improve coverage.
The resulting cells are review candidates, never automatic catalog installs.
"""
import math

from .calibration_statistics import coverage_lower_bound, fit_upper_bound, percentile
from .matrix import MIN_SAMPLES, digest, positive

CELL_FIELDS = (
    "prompt_tokens_min", "prompt_tokens_max", "context_tokens_min", "context_tokens_max",
    "cache_state", "contention", "prefill_tps", "decode_tps", "max_prefill_work_tokens",
    "max_decode_work_tokens", "max_active_requests", "competitor_profile_ids",
    "max_other_model_requests", "max_other_model_service_fraction",
)


def nonnegative(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0


def _cell_errors(cell, context_limit):
    errors = []
    for name in ("prompt_tokens_min", "prompt_tokens_max", "context_tokens_min", "context_tokens_max",
                 "max_decode_work_tokens", "max_active_requests"):
        if type(cell.get(name)) is not int or cell[name] < 1:
            errors.append(f"{name} must be a positive integer")
    for name in ("prefill_tps", "decode_tps"):
        if not positive(cell.get(name)) or cell[name] > 20_000:
            errors.append(f"{name} must be a positive measured rate")
    if type(cell.get("max_prefill_work_tokens")) is not int or cell["max_prefill_work_tokens"] < 0:
        errors.append("prefill work bound must be nonnegative")
    if type(cell.get("max_other_model_requests")) is not int or cell["max_other_model_requests"] < 0:
        errors.append("invalid other-model request bound")
    fraction = cell.get("max_other_model_service_fraction")
    if not nonnegative(fraction) or fraction > 1:
        errors.append("invalid other-model service fraction")
    if cell.get("cache_state") not in ("cold", "reused"):
        errors.append("invalid cache state")
    if cell.get("contention") not in ("isolated", "same_model", "other_model"):
        errors.append("invalid contention")
    competitors = cell.get("competitor_profile_ids")
    if (not isinstance(competitors, list) or
            any(not isinstance(v, str) or not v.strip() for v in competitors) or
            any(len(v) > 256 for v in competitors) or len(competitors) > 16 or
            competitors != sorted(set(competitors))):
        errors.append("competitor profile IDs must be a sorted exact set")
    if errors:
        return errors
    if not (cell["prompt_tokens_min"] <= cell["prompt_tokens_max"] <= cell["context_tokens_max"] <= context_limit
            and cell["context_tokens_min"] <= cell["context_tokens_max"]):
        errors.append("invalid prompt/context interval")
    if cell["contention"] == "other_model":
        if not competitors or cell["max_other_model_requests"] < 1 or fraction <= 0:
            errors.append("other-model cell requires explicit competitor evidence")
    elif competitors or cell["max_other_model_requests"] != 0 or fraction != 0:
        errors.append("non-competing cell cannot certify other-model work")
    if cell["contention"] == "isolated" and cell["max_active_requests"] != 1:
        errors.append("isolated cell must have exactly one active request")
    if cell["contention"] == "same_model" and cell["max_active_requests"] < 2:
        errors.append("same-model contention requires multiple active requests")
    if cell["max_active_requests"] > 64 or cell["max_other_model_requests"] >= cell["max_active_requests"]:
        errors.append("invalid active request envelope")
    return errors


def _sample_errors(sample, cell):
    errors = []
    if not isinstance(sample, dict):
        return ["sample must be an object"]
    for name in ("run_id", "request_id"):
        if not isinstance(sample.get(name), str) or not sample[name]:
            errors.append(f"sample {name} is required")
    if sample.get("partition") not in ("calibration", "validation"):
        errors.append("sample partition must be fixed before collection")
    if not digest(sample.get("raw_receipt_sha256")):
        errors.append("sample raw receipt digest is required")
    if not digest(sample.get("workload_sha256")):
        errors.append("sample numeric/token workload digest is required")
    if sample.get("cache_state") != cell["cache_state"] or sample.get("contention") != cell["contention"]:
        errors.append("sample cache/contention does not match cell")
    if sample.get("competitor_profile_ids") != cell["competitor_profile_ids"]:
        errors.append("sample competitor set does not match cell")
    if type(sample.get("tool_history")) is not bool:
        errors.append("sample must explicitly record tool/history workload")
    for kind in ("prompt", "context"):
        value = sample.get(f"{kind}_tokens")
        if (type(value) is not int or
                not cell[f"{kind}_tokens_min"] <= value <= cell[f"{kind}_tokens_max"]):
            errors.append(f"sample {kind} outside qualified interval")
    for name in ("prefill_work_tokens", "decode_work_tokens", "active_requests", "other_model_requests"):
        value = sample.get(name)
        if type(value) is not int or not 0 <= value <= cell[f"max_{name}"]:
            errors.append(f"sample {name} outside qualified bound")
    if sample.get("active_requests") == 0:
        errors.append("target must be included in active request count")
    if sample.get("prefill_work_tokens") == 0 and sample.get("decode_work_tokens") == 0:
        errors.append("zero-work samples cannot train a latency predictor")
    fraction = sample.get("other_model_service_fraction")
    if not nonnegative(fraction) or fraction > cell["max_other_model_service_fraction"]:
        errors.append("sample other-model fraction outside qualified bound")
    observed = sample.get("observed_first_content_ms")
    censored = sample.get("censored_after_ms")
    if not positive(observed) or censored is not None:
        errors.append("censored/refused/unobserved first-content sample cannot certify coverage")
    return errors


def evaluate_calibration(receipt, report_sha256, context_limit):
    """Return wire candidate plus full statistical evidence, or closed errors."""
    result = {"qualified": False, "errors": [], "cells": [], "calibration": None}
    errors = result["errors"]
    if not isinstance(receipt, dict) or receipt.get("version") != 1:
        errors.append("deadline calibration receipt version must be 1")
        return result
    contract = receipt.get("prompt_contract_id")
    cells = receipt.get("cells")
    target = receipt.get("tail_coverage", .95)
    confidence = receipt.get("coverage_confidence", .95)
    require_confidence = receipt.get("require_confidence_bound", True)
    if not digest(contract):
        errors.append("verified prompt_contract_id digest is required")
    if not isinstance(cells, list) or not 1 <= len(cells) <= 128:
        errors.append("requires 1...128 calibration cells")
    if not positive(target) or not .95 <= target < 1 or not positive(confidence) or not .5 < confidence < 1:
        errors.append("invalid tail coverage/confidence target")
    if type(require_confidence) is not bool:
        errors.append("require_confidence_bound must be boolean")
    if errors:
        return result
    partitions = {"calibration": set(), "validation": set()}
    request_ids = set()
    workload_partitions = {"calibration": set(), "validation": set()}
    output = []
    for index, cell in enumerate(cells):
        problems = _cell_errors(cell, context_limit) if isinstance(cell, dict) else ["cell must be an object"]
        observations = cell.get("samples", []) if isinstance(cell, dict) else []
        if not isinstance(observations, list) or not 2 * MIN_SAMPLES <= len(observations) <= 10_000:
            problems.append("cell requires bounded calibration and validation samples")
        if problems:
            errors.extend(f"cell {index}: {problem}" for problem in problems)
            continue
        run_ids = set()
        workload_ids = set()
        for sample in observations:
            problems.extend(_sample_errors(sample, cell))
            if problems:
                continue
            identity = (sample["run_id"], sample["request_id"])
            if identity in request_ids:
                problems.append("duplicate logical request observation")
            request_ids.add(identity)
            partitions[sample["partition"]].add(sample["run_id"])
            workload_partitions[sample["partition"]].add(sample["workload_sha256"])
            if sample["run_id"] in run_ids or sample["workload_sha256"] in workload_ids:
                problems.append("repeated runs or identical prompts cannot inflate independent sample count")
            run_ids.add(sample["run_id"])
            workload_ids.add(sample["workload_sha256"])
        if problems:
            errors.extend(f"cell {index}: {problem}" for problem in sorted(set(problems)))
            continue
        split = {name: [s for s in observations if s["partition"] == name] for name in partitions}
        if any(len(samples) < MIN_SAMPLES for samples in split.values()):
            errors.append(f"cell {index}: each partition requires {MIN_SAMPLES} samples")
            continue
        # Each cell certifies its own maximum work envelope; missing the upper
        # endpoint cannot authorize extrapolation to a larger scheduler load.
        for name in ("prefill_work_tokens", "decode_work_tokens", "active_requests",
                     "other_model_requests", "other_model_service_fraction"):
            if max(s[name] for s in observations) < cell[f"max_{name}"]:
                problems.append(f"{name} maximum was not measured")
        for kind in ("prompt", "context"):
            values = [s[f"{kind}_tokens"] for s in observations]
            if min(values) > cell[f"{kind}_tokens_min"] or max(values) < cell[f"{kind}_tokens_max"]:
                problems.append(f"{kind} interval endpoints were not measured")
        if not all(any(s["tool_history"] for s in split[name]) for name in split):
            problems.append("tool/history workload must be present in both partitions")
        def base(sample):
            return 1000 * (sample["prefill_work_tokens"] / cell["prefill_tps"]
                           + sample["decode_work_tokens"] / cell["decode_tps"])
        ratio, additive = fit_upper_bound([(base(s), s["observed_first_content_ms"]) for s in split["calibration"]])
        residuals = [s["observed_first_content_ms"] - (base(s) * ratio + additive) for s in split["validation"]]
        covered = sum(value <= 0 for value in residuals)
        count = len(residuals)
        coverage = covered / count
        lower = coverage_lower_bound(covered, count, confidence)
        if coverage < target or lower < target:
            problems.append("independent validation tail coverage did not qualify")
        if not require_confidence:
            problems.append("evidence-only relaxed confidence reports cannot promote a profile")
        wire = {name: cell[name] for name in CELL_FIELDS}
        wire.update(error_ratio=ratio, error_additive_ms=additive,
                    calibration_sample_count=len(split["calibration"]), validation_sample_count=count,
                    validation_covered_count=covered, tail_coverage=target, report_sha256=report_sha256)
        result["cells"].append({"index": index, "qualified": not problems, "errors": problems,
                                "empirical_coverage": coverage, "coverage_lower_bound": lower,
                                "coverage_confidence": confidence, "confidence_gate_required": require_confidence,
                                "validation_error_p50_ms": percentile(residuals, .5),
                                "validation_error_p95_ms": percentile(residuals, .95),
                                "validation_error_max_ms": max(residuals), "candidate": wire})
        errors.extend(f"cell {index}: {problem}" for problem in problems)
        output.append(wire)
    if partitions["calibration"] & partitions["validation"]:
        errors.append("a run occurs in both calibration and validation partitions")
    if workload_partitions["calibration"] & workload_partitions["validation"]:
        errors.append("identical prompt work occurs in both calibration and validation partitions")
    if not errors and output:
        result.update(qualified=True, calibration={"version": 1, "prompt_contract_id": contract, "cells": output})
    return result
