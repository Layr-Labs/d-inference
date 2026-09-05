"""Content-free diagnostic trace parsing and completeness checks."""

import json
from pathlib import Path

OPS = dict(enumerate((
    "none", "embedding", "gated_delta_net", "full_attention", "attention_projection",
    "moe_routing", "moe_experts", "shared_expert", "layer_residual", "final_norm",
    "lm_head", "input_norm", "query_projection", "query_norm", "key_projection",
    "key_norm", "value_projection", "value_norm", "attention", "output_projection",
    "post_attention_norm", "dense_feed_forward", "dense_gate_projection",
    "dense_up_projection", "dense_down_projection", "routed_expert_gate_projection",
    "routed_expert_up_projection", "routed_expert_down_projection", "moe_combine",
    "weighted_expert_unsort", "per_layer_input", "sliding_attention",
)))
OPEN_FIELDS = (
    "open_runs", "open_requests", "open_chunks", "open_decode_steps",
    "open_primitives", "open_command_buffers",
)
TIMING_NOTE = (
    "Diagnostic data only. Host graph scope times include tracing and nested scopes; "
    "they are not GPU times and must not be added across nested operations. Public "
    "command-buffer GPU intervals overlap and are not per-kernel timings. Dispatch "
    "counts and shapes describe captured work, not hardware utilization or DRAM traffic. "
    "Use separate untraced baselines for latency and throughput claims."
)


def events(path):
    """Read NDJSON without retaining the full trace in memory."""
    with path.open() as stream:
        for number, line in enumerate(stream, 1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
                if not isinstance(item, dict) or not isinstance(item.get("kind"), str):
                    raise ValueError("event requires an object and kind")
                yield item
            except (ValueError, TypeError) as error:
                raise ValueError(f"{path.name}:{number}: invalid trace event") from error


def load_object(path, errors):
    try:
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise ValueError("expected object")
        return value
    except (OSError, ValueError):
        errors.append(f"missing or invalid {path.name}")
        return {}


def validate_metadata(root, manifest, summary, event_count, errors):
    for label, data, drop_field, count_field in (
        ("manifest", manifest, "records_dropped", "records_written"),
        ("summary", summary, "dropped_records", "records"),
    ):
        if data.get("complete") is not True:
            errors.append(f"{label} incomplete")
        for key in (drop_field, "explicit_failures", "scope_errors", *OPEN_FIELDS):
            if data.get(key) != 0:
                errors.append(f"{label}.{key} must be zero (got {data.get(key)!r})")
        if data.get("primitive_context_association_exhausted") is not False:
            errors.append(f"{label} primitive context association missing or exhausted")
        if data.get(count_field) != event_count:
            errors.append(f"{label} event count disagrees with NDJSON")
    if manifest.get("schema_version") != 1:
        errors.append("unsupported or missing trace schema_version")
    requested = bool(manifest.get("gpu_capture_selected_chunks") or
                     manifest.get("gpu_capture_selected_decode_steps"))
    bundles = sorted(p.name for p in root.glob("*.gputrace"))
    failed = manifest.get("gpu_capture_incomplete") is not False
    failed |= manifest.get("gpu_capture_security_failure_stage") != 0
    failed |= manifest.get("gpu_capture_security_failure_errno") != 0
    if requested and (failed or not bundles):
        errors.append("requested GPU capture is missing, incomplete, or failed")
    return {"requested": requested, "bundles": bundles,
            "status": "failed_or_incomplete" if failed and requested else
                      "present" if bundles else "not_requested",
            "replay_validated": False,
            "note": "Bundle presence and tracer lifecycle are checked; replay is a separate check."}


def interval_metrics(intervals):
    ordered = sorted((a, b) for a, b in intervals if a > 0 and b >= a)
    merged = []
    for start, end in ordered:
        if merged and start <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    union = sum(b - a for a, b in merged)
    span = merged[-1][1] - merged[0][0] if merged else 0
    return {"public_gpu_interval_count": len(ordered), "public_gpu_union_ns": union,
            "public_gpu_span_ns": span, "uncovered_interval_ns": span - union,
            "public_gpu_overlap_ns": sum(b - a for a, b in ordered) - union}
