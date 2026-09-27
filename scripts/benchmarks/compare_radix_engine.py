#!/usr/bin/env python3
"""Compare full generated-token evidence, retaining failures in a JSON verdict."""

import argparse
import gzip
import json
from pathlib import Path
import statistics

from radix_engine_evidence import report_errors


def read(path):
    data = Path(path).read_bytes()
    return json.loads(gzip.decompress(data) if str(path).endswith(".gz") else data)


def mismatch(left, right):
    differences = []
    for key in ("prompt_token_ids", "token_ids", "finish", "prompt_tokens", "completion_tokens"):
        if left.get(key) != right.get(key):
            differences.append(key)
    if not left.get("token_ids") or not right.get("token_ids"):
        differences.append("empty_output")
    if left.get("finish") not in ("stop", "length") or right.get("finish") not in ("stop", "length"):
        differences.append("unclean_terminal")
    for row in (left, right):
        if row.get("completion_tokens", 0) != len(row.get("token_ids", [])):
            differences.append("token_count_inconsistent")
    return sorted(set(differences))


def compare(baseline, candidate, expect_hits=False, axis="cache"):
    if axis not in ("cache", "backend"):
        raise ValueError("comparison axis must be cache or backend")
    errors = []
    for name, report in (("baseline", baseline), ("candidate", candidate)):
        errors.extend(dict(error, report=name) for error in report_errors(report))
        ids = [row.get("id") for row in report.get("rows", [])]
        if len(ids) != len(set(ids)):
            errors.append({"report": name, "duplicate_request_ids": True})
    if errors and any(report.get("schema", 1) >= 2 for report in (baseline, candidate)):
        return {"passed": False, "errors": errors, "rows": [], "generated_token_ids_compared": False,
                "actual_model_batch_width_verified": False,
                "comparison_axis": axis}
    left = {row["id"]: row for row in baseline["rows"]}
    right = {row["id"]: row for row in candidate["rows"]}
    if [row["id"] for row in baseline["rows"]] != [row["id"] for row in candidate["rows"]]:
        errors.append({"request_order_difference": True})
    same_configuration = ["model", "mtp", "kv_budget_bytes", "schema",
                          "verified_model_hash", "input_sha256", "runtime_identity",
                          "kv_grant_mode", "production_grant", "cancellation_probe_version"]
    if axis == "backend":
        same_configuration += ["cache_requested", "cache_mode_requested", "key_mode_requested"]
        if any(report.get("requested_backend") != expected or report.get("resolved_backend") != expected
               for report, expected in ((baseline, "contiguous"), (candidate, "paged"))):
            errors.append({"expected_contiguous_to_paged_pair": True})
    else:
        same_configuration.append("resolved_backend")
        if baseline.get("schema", 1) >= 2 and candidate.get("schema", 1) >= 2:
            same_configuration += ["cache_mode_requested", "key_mode_requested"]
            if baseline.get("cache_requested") is not False or candidate.get("cache_requested") is not True:
                errors.append({"expected_cache_off_to_on_pair": True})
    for key in same_configuration:
        if baseline.get(key) != candidate.get(key):
            errors.append({"configuration_difference": key})
    if baseline.get("max_concurrent_requests", 1) != candidate.get("max_concurrent_requests", 1):
        errors.append({"configuration_difference": "max_concurrent_requests"})
    for name, report in (("baseline", baseline), ("candidate", candidate)):
        requested = report.get("requested_backend")
        if requested in ("paged", "contiguous") and (
            report.get("resolved_backend") != requested or report.get("backend_fallback")
        ):
            errors.append({"report": name, "requested_backend_not_active": requested})
    if baseline.get("metrics_loaded", {}).get("assistant_identity") != candidate.get("metrics_loaded", {}).get("assistant_identity"):
        errors.append({"configuration_difference": "assistant_identity"})
    if set(left) != set(right):
        errors.append({"request_set_difference": sorted(set(left) ^ set(right))})
    rows = []
    for name, old in left.items():
        if name not in right:
            continue
        new = right[name]
        differences = mismatch(old, new)
        if old.get("prompt_render_date") != new.get("prompt_render_date"):
            differences.append("prompt_render_date")
        if differences:
            errors.append({"id": name, "differences": differences})
        if any(row.get("outcome", "completed") != "completed" for row in (old, new)):
            errors.append({"id": name, "batch_request_failed": True,
                           "baseline_error": old.get("error"), "candidate_error": new.get("error")})
            continue
        if expect_hits and new["kind"] in ("repeat", "branch", "branch-repeat", "turn2", "turn2-repeat", "continuation") and new["prompt_tokens"] > 4096:
            if new["saved_tokens"] <= 0:
                errors.append({"id": name, "missing_expected_long_prefix_hit": True})
        rows.append({"id": name, "token_ids_equal": not differences,
                     "baseline_ttft_s": old["ttft_s"], "candidate_ttft_s": new["ttft_s"],
                     "saved_tokens": new["saved_tokens"], "cache_outcome": new["cache_outcome"],
                     "baseline_terminal_tail_s": old["elapsed_s"] - old["chunks"][-1]["elapsed_s"],
                     "candidate_terminal_tail_s": new["elapsed_s"] - new["chunks"][-1]["elapsed_s"]})
    tenants = candidate["tenant_checks"]
    if len(baseline["tenant_checks"]) != len(tenants) or any(
        mismatch(old, new) for old, new in zip(baseline["tenant_checks"], tenants)
    ):
        errors.append({"tenant_baseline_output_mismatch": True})
    if len(tenants) != 3 or any(mismatch(tenants[0], row) for row in tenants[1:]):
        errors.append({"tenant_output_mismatch": True})
    if len(tenants) == 3:
        if tenants[2]["saved_tokens"] != 0:
            errors.append({"cross_tenant_cache_hit": True})
        if expect_hits and tenants[1]["saved_tokens"] <= 0:
            errors.append({"tenant_warm_control_did_not_hit": True})
    if mismatch(baseline["recovered"], candidate["recovered"]):
        errors.append({"cancellation_recovery_output_mismatch": True})
    cancelled = candidate["cancelled"]
    recovered = candidate["recovered"]
    if cancelled["finish"] != "cancelled" or not cancelled["cancel_requested"]:
        errors.append({"cancellation_not_observed": True})
    if cancelled["token_ids"] != recovered["token_ids"][:len(cancelled["token_ids"])]:
        errors.append({"cancelled_output_is_not_a_prefix": True})
    # Paged L1 publishes completed prefill blocks before decode. Those exact
    # blocks remain valid if later decoding is cancelled. Hybrid checkpoint
    # publication is fenced on natural donor termination instead.
    complete_checkpoint = any(row.get("metrics_after", {}).get("cache_mode") == "ssd_complete"
                              for row in candidate["rows"])
    paged_publication = candidate.get("resolved_backend") == "paged" and not complete_checkpoint
    primed_cancel = candidate.get("cancellation_probe_version") == 2
    if primed_cancel and mismatch(baseline.get("cancel_donor", {}), candidate.get("cancel_donor", {})):
        errors.append({"cancellation_donor_output_mismatch": True})
    # Version 2 already has a naturally completed donor in the cancel scope;
    # its surviving checkpoint is valid independently of cancelled publication.
    if recovered["saved_tokens"] and not paged_publication and not primed_cancel:
        errors.append({"cancelled_donor_published_cache": True})
    probes = candidate["rows"] + tenants + [cancelled, recovered]
    if primed_cancel:
        probes.append(candidate["cancel_donor"])
    budget = candidate.get("hybrid_cache_requested_budget_bytes")
    for row in probes:
        for moment in ("metrics_before", "metrics_after"):
            stats = row.get(moment, {}).get("hybrid_cache")
            if stats is not None and budget is not None and not 0 <= stats["retained_bytes"] <= budget:
                errors.append({"id": row["id"], "cache_budget_violation": stats["retained_bytes"], "moment": moment})
        if candidate.get("cache_mode_requested") == "ssd":
            after = row.get("metrics_after", {})
            if after.get("memory_cache_enabled") or after.get("resident_bank_budget_bytes", 0):
                errors.append({"id": row["id"], "unexpected_resident_cache": True})
            if candidate.get("cache_requested") and after.get("cache_mode") not in ("ssd_complete", "ssd_attention"):
                errors.append({"id": row["id"], "ssd_store_unavailable": True})
            requested_key = candidate.get("key_mode_requested")
            if after.get("cache_mode") == "ssd_complete" and requested_key and after.get("key_mode") != requested_key:
                errors.append({"id": row["id"], "unexpected_key_mode": after.get("key_mode")})
            ssd = after.get("ssd_cache")
            if after.get("cache_mode") == "ssd_complete" and not isinstance(ssd, dict):
                errors.append({"id": row["id"], "ssd_metrics_missing": True})
            if ssd:
                if not row.get("batch_id") and ssd.get("staged_bytes_in_use") != 0:
                    errors.append({"id": row["id"], "idle_staging_not_released": True})
                if not 0 <= ssd.get("maximum_segment_bytes", -1) <= 4 * 1024 * 1024:
                    errors.append({"id": row["id"], "unbounded_checkpoint_segment": True})
                before = row.get("metrics_before", {}).get("ssd_cache", {})
                if row.get("saved_tokens", 0) > 0 and (
                    row.get("ssd_stage_disposition") != "staged"
                    or ssd.get("stage_read_bytes", 0) <= before.get("stage_read_bytes", 0)
                ):
                    errors.append({"id": row["id"], "ssd_hit_without_authenticated_read": True})
        if candidate.get("mtp", "").startswith("on") and not row.get("metrics_after", {}).get("mtp", {}).get("active"):
            errors.append({"id": row["id"], "requested_mtp_not_active": True})

    for name, report in (("baseline", baseline), ("candidate", candidate)):
        concurrency = report.get("max_concurrent_requests", 1)
        if concurrency <= 1:
            continue
        batches = report.get("batches", [])
        expected_ids = {row.get("batch_id") for row in report["rows"]}
        if None in expected_ids or {batch["id"] for batch in batches} != expected_ids:
            errors.append({"report": name, "missing_batch_evidence": True})
        for batch in batches:
            members = [row for row in report["rows"] if row.get("batch_id") == batch["id"]]
            if (len(members) != concurrency or batch.get("concurrency_requested") != concurrency
                    or batch.get("completed") != concurrency or batch.get("failed") != 0):
                errors.append({"report": name, "batch_id": batch["id"], "incomplete_batch": True})
            if batch.get("peak_active_requests", 0) < 2:
                errors.append({"report": name, "batch_id": batch["id"], "concurrency_not_observed": True})
            after = batch.get("metrics_after_batch", {})
            if after.get("ssd_cache", {}).get("staged_bytes_in_use", 0) != 0:
                errors.append({"report": name, "batch_id": batch["id"], "idle_staging_not_released": True})
            capacity = after.get("capacity", {})
            if capacity.get("active_requests", 0) or capacity.get("waiting_requests", 0):
                errors.append({"report": name, "batch_id": batch["id"], "batch_not_drained": True})

    def decode(report):
        values = [row["decode_tps"] for row in report["rows"]
                  if row["kind"] == "decode" and row.get("outcome") != "failed"]
        return statistics.median(values) if values else None

    return {"passed": not errors, "errors": errors, "rows": rows, "comparison_axis": axis,
            "generated_token_ids_compared": True,
            "actual_model_batch_width_verified": all(report.get("schema", 1) >= 3 for report in (baseline, candidate)),
            "cancellation_cache_policy": "completed priming donor remains reusable" if primed_cancel else (
                "finalized paged blocks may be reused" if paged_publication else "cancelled hybrid donor must not publish"),
            "baseline_decode_tps": decode(baseline), "candidate_decode_tps": decode(candidate)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    parser.add_argument("--expect-cache-hits", action="store_true")
    parser.add_argument("--axis", choices=["cache", "backend"], default="cache",
                        help="Default compares one backend's cache arms; backend requires contiguous→paged with equal cache settings")
    args = parser.parse_args()
    verdict = compare(read(args.baseline), read(args.candidate), args.expect_cache_hits, args.axis)
    print(json.dumps(verdict, indent=2))
    raise SystemExit(0 if verdict["passed"] else 1)


if __name__ == "__main__":
    main()
