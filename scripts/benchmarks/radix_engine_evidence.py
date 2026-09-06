"""Integrity checks for direct benchmark schema-2/3 evidence."""

import math
from radix_forward_shapes import report_forward_shape_errors


def digest(value):
    return isinstance(value, str) and len(value) == 64 and all(c in "0123456789abcdef" for c in value)


def memory_errors(memory):
    required = ("cap_bytes", "activation_reserve_bytes", "active_bytes", "cache_bytes",
                "charged_bytes", "materialized_bytes", "unmaterialized_bytes", "remaining_bytes",
                "commitment_debt_bytes", "owner_count", "closing_owner_count", "policy_epoch",
                "generation", "sample_seq")
    if not isinstance(memory, dict) or any(type(memory.get(key)) is not int or memory[key] < 0 for key in required):
        return ["missing_or_invalid_process_memory"]
    if memory["charged_bytes"] < memory["materialized_bytes"] or (
        memory["charged_bytes"] - memory["materialized_bytes"] != memory["unmaterialized_bytes"]
    ) or memory["closing_owner_count"] > memory["owner_count"]:
        return ["inconsistent_process_ownership"]
    available = memory.get("system_available_bytes")
    cap_free = max(0, memory["cap_bytes"] - memory["active_bytes"] - memory["cache_bytes"])
    if available is not None and (type(available) is not int or available < 0):
        return ["invalid_system_available_bytes"]
    headroom = max(0, min(cap_free, available if available is not None else cap_free)
                   - memory["activation_reserve_bytes"])
    outstanding = memory["unmaterialized_bytes"]
    if (memory["remaining_bytes"] != max(0, headroom - outstanding)
            or memory["commitment_debt_bytes"] != max(0, outstanding - headroom)):
        return ["inconsistent_process_headroom"]
    return []


def retirement_errors(metrics, paged, shutdown=False):
    """Inspect post-terminal/IO-drain snapshots, not sampled memory peaks."""
    errors = []
    capacity = metrics.get("capacity", {})
    for key in ("active_requests", "waiting_requests", "kv_in_use_bytes"):
        if type(capacity.get(key)) is not int or capacity[key] != 0:
            errors.append("idle_" + key + "_not_retired")
    # Admission reserves max(physical backing, logical promises) plus auxiliary
    # owners. Empty reusable segments may remain charged after a serial row.
    # The benchmark drains terminal donation and staging before these snapshots.
    expected_reserved = 0
    if paged:
        storage = metrics.get("paged_storage", {})
        for key in ("live_page_bytes", "reserved_page_bytes"):
            if type(storage.get(key)) is not int or storage[key] != 0:
                errors.append("idle_" + key + "_not_retired")
        committed = storage.get("committed_bytes")
        if type(committed) is not int or committed < 0:
            errors.append("missing_committed_backing")
        else:
            expected_reserved = committed
        if shutdown and any(type(storage.get(key)) is not int or storage[key] != 0
                            for key in ("committed_bytes", "segment_count")):
            errors.append("shutdown_native_backing_not_retired")
    if type(capacity.get("kv_reserved_bytes")) is not int or capacity["kv_reserved_bytes"] != expected_reserved:
        errors.append("idle_kv_reservation_backing_mismatch")
    ssd = metrics.get("ssd_cache")
    if isinstance(ssd, dict) and (type(ssd.get("staged_bytes_in_use")) is not int
                                  or ssd["staged_bytes_in_use"] != 0):
        errors.append("idle_staging_not_released")
    if shutdown:
        memory = metrics.get("process_memory", {})
        if any(type(memory.get(key)) is not int or memory[key] != 0 for key in
               ("owner_count", "closing_owner_count", "charged_bytes", "materialized_bytes", "unmaterialized_bytes")):
            errors.append("shutdown_process_owners_not_retired")
    # address_pages is reusable logical addressing. MLX active/cache and RSS
    # include retained model weights and allocator memory, not retired owners.
    return errors


def decode_timing_errors(row):
    """Reconstruct measured decode work from raw chunks, including MTP chunks."""
    chunks = [chunk for chunk in row.get("chunks", []) if chunk.get("tokens")]
    if not chunks:
        return ["missing_decode_chunks"]
    first_count = len(chunks[0]["tokens"])
    after_first = sum(len(chunk["tokens"]) for chunk in chunks[1:])
    span = chunks[-1]["elapsed_s"] - chunks[0]["elapsed_s"]
    expected = after_first / span if span > 0 else 0
    observed = row.get("decode_tps")
    if (row.get("first_delta_token_count") != first_count
            or row.get("decode_tokens_after_first_delta") != after_first
            or type(observed) not in (int, float)
            or not math.isclose(observed, expected, rel_tol=1e-6, abs_tol=1e-6)):
        return ["decode_timing_inconsistent_with_chunks"]
    return []



def production_grant_errors(report):
    """A logical production grant is distinct from live post-build headroom."""
    mode = report.get("kv_grant_mode", "explicit")
    if mode == "explicit":
        return ["unexpected_production_grant"] if report.get("production_grant") else []
    if mode != "production_single_slot":
        return ["invalid_kv_grant_mode"]
    grant = report.get("production_grant")
    fields = ("physical_bytes", "hard_cap_bytes", "effective_cap_bytes", "operator_reserve_bytes",
              "activation_reserve_bytes", "target_weight_bytes", "assistant_weight_bytes",
              "resident_weight_bytes", "ram_prefix_allowance_bytes", "slot_count", "fleet_budget_bytes", "grant_bytes")
    if not isinstance(grant, dict) or any(type(grant.get(key)) is not int or grant[key] < 0 for key in fields):
        return ["missing_production_grant_inputs"]
    fraction = grant.get("cap_fraction")
    if type(fraction) not in (int, float) or not math.isfinite(fraction) or not 0 < fraction <= 1:
        return ["invalid_production_cap_fraction"]
    gib = 1 << 30
    hard = min(int(grant["physical_bytes"] * fraction), max(0, grant["physical_bytes"] - 2 * gib))
    effective = min(hard, max(0, grant["physical_bytes"] - grant["operator_reserve_bytes"]))
    fleet = max(0, effective - grant["resident_weight_bytes"] - grant["activation_reserve_bytes"])
    if (grant["hard_cap_bytes"] != hard or grant["effective_cap_bytes"] != effective
            or grant["resident_weight_bytes"] != grant["target_weight_bytes"] + grant["assistant_weight_bytes"]
            or grant["ram_prefix_allowance_bytes"] != 0 or grant["slot_count"] != 1
            or grant["fleet_budget_bytes"] != fleet or grant["grant_bytes"] != fleet
            or fleet < gib or report.get("kv_budget_bytes") != fleet):
        return ["inconsistent_production_grant"]
    loaded = report.get("metrics_loaded", {})
    process = loaded.get("process_memory", {})
    if (loaded.get("production_grant") != grant or loaded.get("engine_kv_capacity_bytes") != fleet
            or type(loaded.get("post_build_headroom_bytes")) is not int
            or loaded["post_build_headroom_bytes"] < gib
            or process.get("cap_bytes") != effective
            or process.get("activation_reserve_bytes") != grant["activation_reserve_bytes"]):
        return ["production_grant_missing_live_gate_or_authority"]
    return []


def cancellation_errors(report):
    """Version 2 primes the same scope and proves restored-prefix cancellation."""
    version = report.get("cancellation_probe_version", 1)
    if type(version) is not int:
        return ["invalid_cancellation_probe_version"]
    if version == 1:
        return []  # Historical evidence proves cold cancellation only.
    if version != 2:
        return ["invalid_cancellation_probe_version"]
    donor, cancelled, recovered = (report.get(key, {}) for key in ("cancel_donor", "cancelled", "recovered"))
    if donor.get("outcome") != "completed" or donor.get("finish") not in ("stop", "length"):
        return ["cancel_donor_not_completed"]
    if (not donor.get("scope") or any(row.get("scope") != donor["scope"] for row in (cancelled, recovered))
            or not donor.get("prompt_token_ids")
            or any(row.get("prompt_token_ids") != donor["prompt_token_ids"] for row in (cancelled, recovered))):
        return ["cancel_scope_or_prompt_not_primed"]
    if (cancelled.get("outcome") != "cancelled" or cancelled.get("finish") != "cancelled"
            or cancelled.get("cancel_requested") is not True
            or report.get("cancellation_probe_outcome") != "observed"):
        return ["cancellation_not_observed"]
    tokens = donor.get("token_ids", [])
    prefix = cancelled.get("token_ids", [])
    if (not tokens or not prefix or recovered.get("outcome") != "completed"
            or recovered.get("token_ids") != tokens or tokens[:len(prefix)] != prefix):
        return ["cancellation_donor_recovery_token_mismatch"]
    if report.get("cache_mode_requested") == "ssd" and report.get("cache_requested") and report.get("resolved_backend") == "paged":
        before = cancelled.get("metrics_before", {}).get("ssd_cache", {}).get("stage_read_bytes")
        after = cancelled.get("metrics_after", {}).get("ssd_cache", {}).get("stage_read_bytes")
        if (cancelled.get("cache_outcome") != "hit" or cancelled.get("ssd_stage_disposition") != "staged"
                or any(type(cancelled.get(key)) is not int or cancelled[key] <= 0 for key in ("saved_tokens", "matched_tokens"))
                or type(before) is not int or type(after) is not int or before < 0 or after <= before):
            return ["cancel_after_restore_not_exercised"]
    elif report.get("cache_requested") is False and (cancelled.get("saved_tokens", 0) != 0 or cancelled.get("cache_outcome") == "hit"):
        return ["cache_disabled_cancel_restored_prefix"]
    return []


def report_errors(report):
    """Do not promote incomplete cells or legacy reports into final evidence."""
    if report.get("schema", 1) < 2:
        return []
    errors = []
    if report.get("status") != "completed":
        errors.append({"incomplete_run": report.get("status"), "error": report.get("error")})
        return errors
    errors.extend({reason: True} for reason in production_grant_errors(report))
    errors.extend({reason: True} for reason in report_forward_shape_errors(report))
    errors.extend({reason: True} for reason in cancellation_errors(report))
    rows = report.get("rows", [])
    if not rows or any(row.get("outcome") != "completed" for row in rows):
        errors.append({"incomplete_request_cells": True})
    if report.get("warmup", {}).get("outcome") != "completed":
        errors.append({"warmup_not_completed": True})
    identity = report.get("runtime_identity", {})
    if report.get("cache_mode_requested") == "ssd":
        if (not digest(report.get("verified_model_hash")) or not digest(report.get("input_sha256"))
                or not all(identity.get(key) for key in ("normalization", "renderer", "tokenizer"))
                or not all(digest(identity.get(key)) for key in ("binary_sha256", "metallib_sha256"))):
            errors.append({"missing_artifact_identity": True})
    if report.get("expected_model_sha256") and report["expected_model_sha256"] != report.get("verified_model_hash"):
        errors.append({"pinned_model_mismatch": True})
    controls = report.get("tenant_checks", []) + [report.get("cancelled", {}), report.get("recovered", {})]
    if report.get("cancellation_probe_version") == 2:
        controls.append(report.get("cancel_donor", {}))
    probes = rows + controls
    for row in probes:
        if row.get("outcome") not in ("completed", "cancelled"):
            errors.append({"id": row.get("id"), "incomplete_control_cell": row.get("outcome")})
            continue
        if report.get("cache_requested") is False and (
            row.get("saved_tokens") != 0 or row.get("cache_outcome") == "hit"
        ):
            errors.append({"id": row.get("id"), "cache_disabled_probe_restored_prefix": True})
        chunks = row.get("chunks", [])
        if [token for chunk in chunks for token in chunk.get("tokens", [])] != row.get("token_ids"):
            errors.append({"id": row.get("id"), "chunk_token_ids_inconsistent": True})
        for reason in decode_timing_errors(row):
            errors.append({"id": row.get("id"), reason: True})
        if row.get("prompt_tokens") != len(row.get("prompt_token_ids", [])):
            errors.append({"id": row.get("id"), "prompt_token_count_inconsistent": True})
        if report.get("cache_mode_requested") == "ssd" and not row.get("prompt_render_date"):
            errors.append({"id": row.get("id"), "missing_request_owned_date": True})
    observations = []
    for row in probes:
        for moment in ("metrics_before", "metrics_after"):
            observations.append((row.get("id"), moment, row.get(moment, {}), not row.get("batch_id") and moment == "metrics_after"))
    for batch in report.get("batches", []):
        observations.append((batch.get("id"), "metrics_after_batch", batch.get("metrics_after_batch", {}), True))
        observations.extend((batch.get("id"), "capacity_sample", sample, False)
                            for sample in batch.get("capacity_samples", []))
    observations.extend(("run", key, report.get(key, {}), key == "metrics_after_shutdown")
                        for key in ("metrics_loaded", "metrics_after_shutdown"))
    if report.get("cache_mode_requested") == "ssd":
        for owner, moment, metrics, idle in observations:
            for reason in memory_errors(metrics.get("process_memory")):
                errors.append({"id": owner, "moment": moment, reason: True})
            if idle:
                for reason in retirement_errors(metrics, report.get("resolved_backend") == "paged",
                                                shutdown=moment == "metrics_after_shutdown"):
                    errors.append({"id": owner, "moment": moment, reason: True})
            if report.get("resolved_backend") == "paged" and (
                moment in ("metrics_after", "metrics_after_batch") or "paged_storage" in metrics
            ):
                storage = metrics.get("paged_storage", {})
                if any(type(storage.get(key)) is not int or storage[key] < 0
                       for key in ("allocator_padding_bytes", "last_allocation_allowance_bytes")):
                    errors.append({"id": owner, "moment": moment, "missing_allocator_footprint": True})
            ssd = metrics.get("ssd_cache")
            if ssd is not None:
                if any(type(ssd.get(key)) is not int or ssd[key] < 0 for key in
                       ("write_host_bytes_in_use", "peak_write_host_bytes", "write_host_capacity_refusals")):
                    errors.append({"id": owner, "moment": moment, "missing_write_host_evidence": True})
                elif idle and ssd["write_host_bytes_in_use"] != 0:
                    errors.append({"id": owner, "moment": moment, "idle_write_host_not_released": True})
    if report.get("mtp", "").startswith("on"):
        assistant = report.get("metrics_loaded", {}).get("assistant_identity", {})
        if report.get("cache_mode_requested") == "ssd" and (not assistant or assistant.get("source") in (None, "none")):
            errors.append({"missing_assistant_identity": True})
        # Batching can skip individual rows under the ordinary MTP policy;
        # prove actual rounds somewhere in the non-warmup workload.
        rounds = sum(max(0, row.get("metrics_after", {}).get("mtp", {}).get("rounds", 0)
                        - row.get("metrics_before", {}).get("mtp", {}).get("rounds", 0)) for row in probes)
        if rounds == 0:
            errors.append({"requested_mtp_never_verified": True})
    return errors
