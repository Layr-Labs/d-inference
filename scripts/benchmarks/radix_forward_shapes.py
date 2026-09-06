"""Validate bounded actual target-call deltas, never scheduler-width proxies."""

PHASES = {"prefill", "decode", "mtp_verification", "mixed_prefill_decode"}
COMPONENTS = {"siluProduct", "weightedExpertSum", "gelu", "swiGLU", "geGLU",
              "gemmaGelu", "gemmaSoftcap", "gptossExperts"}
MAX_COUNT = (1 << 64) - 1


def integer(value, minimum=0, maximum=MAX_COUNT):
    return type(value) is int and minimum <= value <= maximum


def axes_key(axes):
    allowed = {"phase", "kind", "live_batch_rows", "sequence_width", "physical_batch_rows",
               "physical_component_rows", "component"}
    if not isinstance(axes, dict) or set(axes) - allowed or axes.get("phase") not in PHASES:
        raise ValueError("invalid_or_private_axes")
    kind = axes.get("kind")
    live, sequence, physical = (axes.get(k) for k in ("live_batch_rows", "sequence_width", "physical_batch_rows"))
    if not integer(live, 1, 256) or not integer(sequence, 1, 1 << 20) or not integer(physical, live, 1 << 20):
        raise ValueError("invalid_axes")
    component, rows = axes.get("component"), axes.get("physical_component_rows")
    if kind == "target":
        if component is not None or rows is not None:
            raise ValueError("target_component_confusion")
    elif kind == "compiled_component":
        if component not in COMPONENTS or not integer(rows, 1, 1 << 24):
            raise ValueError("invalid_component_axes")
    else:
        raise ValueError("invalid_kind")
    return axes["phase"], kind, live, sequence, physical, component, rows


def entries(values):
    if not isinstance(values, list) or len(values) > 256:
        raise ValueError("unbounded_entries")
    result = {}
    for value in values:
        if not isinstance(value, dict) or set(value) != {"axes", "submitted_calls", "completed_calls"}:
            raise ValueError("invalid_entry")
        key = axes_key(value.get("axes"))
        submitted, completed = value.get("submitted_calls"), value.get("completed_calls")
        if key in result or not integer(submitted) or not integer(completed, 0, submitted):
            raise ValueError("invalid_or_duplicate_counts")
        result[key] = submitted, completed
    return result


def snapshot(value):
    allowed = {"schema", "scope", "enabled", "entries", "pending_steps", "abandoned_steps",
               "unobserved_dispatches", "dropped_calls"}
    if (not isinstance(value, dict) or set(value) != allowed or not integer(value.get("schema"), 1, 1)
            or value.get("enabled") is not True or not integer(value.get("scope"), 1)):
        raise ValueError("disabled_or_invalid_snapshot")
    for key in ("pending_steps", "abandoned_steps", "unobserved_dispatches", "dropped_calls"):
        if not integer(value.get(key)):
            raise ValueError("invalid_snapshot_counter")
    return entries(value.get("entries"))


def validate_packet(packet, requested):
    """Return actual completed target widths; reject forged/incomplete deltas."""
    if not integer(requested, 1, 256):
        raise ValueError("invalid_requested_width")
    if (not isinstance(packet, dict) or set(packet) != {"schema", "before", "after", "delta"}
            or not integer(packet.get("schema"), 1, 1)):
        raise ValueError("missing_forward_shapes")
    before, after, delta = (packet.get(key) for key in ("before", "after", "delta"))
    old, new = snapshot(before), snapshot(after)
    if before["scope"] != after["scope"] or before["pending_steps"] or after["pending_steps"]:
        raise ValueError("scope_or_pending_steps")
    for key in ("abandoned_steps", "unobserved_dispatches", "dropped_calls"):
        if after[key] != before[key]:
            raise ValueError(key)
    expected = {}
    for key in old.keys() | new.keys():
        a, b = old.get(key, (0, 0)), new.get(key, (0, 0))
        if b[0] < a[0] or b[1] < a[1]:
            raise ValueError("counter_regression")
        difference = b[0] - a[0], b[1] - a[1]
        if difference[0] != difference[1]:
            raise ValueError("unconfirmed_calls")
        if difference != (0, 0):
            expected[key] = difference
    delta_keys = {"schema", "scope", "entries", "complete", "reasons",
                  "pending_steps_before", "pending_steps_after"}
    if (not isinstance(delta, dict) or set(delta) != delta_keys
            or not integer(delta.get("schema"), 1, 1) or not integer(delta.get("scope"), 1)
            or delta.get("scope") != after["scope"]
            or delta.get("complete") is not True or delta.get("reasons") != []
            or not integer(delta.get("pending_steps_before"), 0, 0)
            or not integer(delta.get("pending_steps_after"), 0, 0)
            or entries(delta.get("entries")) != expected):
        raise ValueError("inconsistent_delta")
    targets = {key: count[1] for key, count in expected.items() if key[1] == "target" and count[1] > 0}
    if not targets:
        raise ValueError("no_completed_target_calls")
    by_phase = {phase: sorted({key[2] for key in targets if key[0] == phase}) for phase in sorted(PHASES)}
    decode = any(key[2] == requested and key[0] in ("decode", "mtp_verification") for key in targets)
    any_width = any(key[2] == requested for key in targets)
    return {"live_widths_by_phase": by_phase, "requested_decode_width_observed": decode,
            "requested_prefill_width_observed": requested in by_phase["prefill"],
            "requested_target_width_observed": any_width if requested == 1 else decode,
            "completed_target_calls": sum(targets.values()),
            "meaning": "Observed completed target-call widths, not constant width or kernel launch geometry"}


def report_forward_shape_errors(report):
    if report.get("schema", 1) < 3:
        return []
    if not integer(report.get("forward_shape_telemetry_schema"), 1, 1):
        return ["missing_forward_shape_schema"]
    requested = report.get("max_concurrent_requests", 1)
    if not integer(requested, 1, 256):
        return ["invalid_requested_forward_width"]
    cohorts = report.get("rows", []) if requested == 1 else report.get("batches", [])
    if not cohorts:
        return ["missing_forward_shape_cohorts"]
    errors = []
    for cohort in cohorts:
        try:
            result = validate_packet(cohort.get("forward_shapes"), requested)
            if not result["requested_target_width_observed"]:
                errors.append("requested_actual_target_width_not_observed:" + str(cohort.get("id")))
        except (ValueError, TypeError, KeyError, AttributeError) as error:
            errors.append("forward_shapes:" + str(cohort.get("id")) + ":" + str(error))
    return errors
