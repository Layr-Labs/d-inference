"""Evaluate raw receipts; missing evidence fails closed and cannot expand service."""
import hashlib
import json

from .matrix import CHECKS, IDENTITY_FIELDS, MIN_SAMPLES, cell_key, digest, identity_errors, positive, shapes, widths
from .calibration import evaluate_calibration

METRICS = ("decode_p10_tps", "aggregate_decode_tps", "prefill_tps",
           "first_content_p95_ms", "token_gap_p95_ms")


def measure(cell, identity, mixed_prefill_token_cap=None):
    errors = []
    samples = cell.get("samples", [])
    if not isinstance(samples, list) or len(samples) < MIN_SAMPLES:
        return None, [f"requires at least {MIN_SAMPLES} independent samples"]
    run_ids = [s.get("run_id") if isinstance(s, dict) else None for s in samples]
    if any(not isinstance(r, str) or not r for r in run_ids) or len(set(run_ids)) != len(samples):
        errors.append("independent samples require unique nonempty run_id values")
    checks = cell.get("checks", {})
    for check in CHECKS:
        evidence = checks.get(check, {}) if isinstance(checks, dict) else {}
        if not isinstance(evidence, dict) or evidence.get("passed") is not True or not digest(evidence.get("receipt_sha256")):
            errors.append(f"missing passing {check} receipt")
    if not digest(cell.get("raw_measurements_sha256")):
        errors.append("missing raw measurements receipt")
    if cell.get("failures") != 0 or type(cell.get("failures")) is not int:
        errors.append("failures must be explicitly zero")
    if not positive(cell.get("absolute_first_content_budget_ms")):
        errors.append("missing absolute first-content budget")
    if not positive(cell.get("resolved_activation_floor_bytes")):
        errors.append("missing runtime activation floor")
    for sample in samples:
        if not isinstance(sample, dict) or any(not positive(sample.get(key)) for key in METRICS):
            errors.append("invalid or missing measured rates/latencies")
            continue
        forwards = sample.get("forward_widths", [])
        if (not isinstance(forwards, list) or not forwards or
                any(type(w) is not int or w < 1 or w > cell["width"] for w in forwards) or
                cell["width"] not in forwards):
            errors.append("requested batch width was not observed in actual forwards")
        competitors = sample.get("competing_model_active_requests", {})
        if (not isinstance(competitors, dict) or
                any(type(competitors.get(model)) is not int or competitors[model] < 1
                    for model in cell["competing_models"]) or
                any(model not in cell["competing_models"] and count != 0 for model, count in competitors.items())):
            errors.append("competing-model work was not observed for the serving set")
        # This records explicit per-engine configuration. None selects the
        # existing runtime/model default, which may itself impose a cap.
        observed_cap = sample.get("effective_mixed_prefill_token_cap")
        if ("effective_mixed_prefill_token_cap" not in sample or
                (mixed_prefill_token_cap is None and observed_cap is not None) or
                (mixed_prefill_token_cap is not None and
                 (type(observed_cap) is not int or observed_cap != mixed_prefill_token_cap))):
            errors.append("measured mixed-prefill cap does not match the candidate policy")
        allowed_overrides = [{}]
        if mixed_prefill_token_cap is not None:
            allowed_overrides.append({"DARKBLOOM_CBV2_MIXED_PREFILL_CAP": str(mixed_prefill_token_cap)})
        mtp = identity.get("mtp")
        if (sample.get("mtp_active") is not (mtp is not None) or
                sample.get("mtp") != mtp or sample.get("runtime_policy_overrides") not in allowed_overrides):
            errors.append("sample runtime/MTP configuration does not match the exact candidate")
        if mtp is not None and (not positive(sample.get("mtp_rounds")) or not positive(sample.get("mtp_proposed_tokens"))):
            errors.append("MTP configuration was declared but actual drafting was not observed")
        if sample.get("power_mode") != "automatic" or sample.get("thermal_state") != "nominal":
            errors.append("power/thermal posture missing or throttled")
        fields = ("activation_peak_bytes", "kv_peak_bytes", "resident_bytes",
                  "activation_reserve_bytes", "memory_budget_bytes")
        if any(not positive(sample.get(key)) for key in fields):
            errors.append("missing measured serving-set memory")
            continue
        reserve = sample["activation_reserve_bytes"]
        ram = identity["memory_gb"] * 1024**3
        if (sample["activation_peak_bytes"] > reserve or
                reserve < cell.get("resolved_activation_floor_bytes", float("inf")) or
                sample["resident_bytes"] + reserve + sample["kv_peak_bytes"] > sample["memory_budget_bytes"] or
                sample["memory_budget_bytes"] > min(ram * 0.90, ram - 2 * 1024**3)):
            errors.append("measured memory exceeds existing serving safeguards")
    if errors:
        return None, sorted(set(errors))
    # Conservative aggregation across independent repetitions; never average p10s upward.
    result = {key: (min if key.endswith("tps") else max)(s[key] for s in samples) for key in METRICS}
    if result["prefill_tps"] > 20_000:
        errors.append("prefill rate exceeds the shared admissible envelope")
    if result["first_content_p95_ms"] > cell["absolute_first_content_budget_ms"]:
        errors.append("absolute first-content budget exceeded")
    return result, errors


def evaluate(raw):
    report = json.loads(raw)
    if not isinstance(report, dict) or not isinstance(report.get("identity"), dict):
        raise ValueError("receipt and identity must be JSON objects")
    identity = report.get("identity", {})
    errors = identity_errors(identity)
    cap = report.get("mixed_prefill_token_cap")
    if cap is not None and (type(cap) is not int or cap not in (128, 256, 512)):
        errors.append("mixed_prefill_token_cap must be 128, 256, or 512")
    serving_sets = report.get("serving_sets", [])
    if (not isinstance(serving_sets, list) or [] not in serving_sets or
            not any(isinstance(s, list) and s for s in serving_sets) or
            any(not isinstance(s, list) or any(not isinstance(m, str) or not m for m in s)
                or len(set(s)) != len(s) for s in serving_sets)):
        errors.append("serving_sets must include isolated and explicit competing-model cases")
    if (isinstance(serving_sets, list) and
            any(isinstance(models, list) and identity.get("model_id") in models for models in serving_sets)):
        errors.append("serving_sets cannot use the target model as a competing model")
    if report.get("schema_version") not in (1, 2):
        errors.append("unsupported receipt schema_version")
    result = {"qualified": False, "receipt_sha256": hashlib.sha256(raw).hexdigest(),
              "errors": errors, "widths": [], "profile": None}
    if errors:
        return result
    required = shapes(identity, serving_sets)
    if not required:
        errors.append("configured context has no supported qualification shapes")
        return result
    cells = {}
    for cell in report.get("qualification_cells", []):
        try:
            key = cell_key(cell)
            if key in cells:
                errors.append(f"duplicate cell {key}")
            cells[key] = cell
        except (KeyError, TypeError):
            errors.append("malformed qualification cell")
    if errors:
        return result
    measured = {}
    selected = []
    previous_width = None
    blocked_by_width = None
    for width in widths(identity):
        failures = []
        if blocked_by_width is not None:
            failures.append(f"lower required width {blocked_by_width} did not qualify")
        for shape in required:
            key = (width, *shape)
            cell = cells.get(key)
            if cell is None:
                failures.append(f"missing {key}")
                continue
            metrics, problems = measure(cell, identity, report.get("mixed_prefill_token_cap"))
            if metrics:
                measured[key] = metrics
                baseline = measured.get((1, *shape))
                if metrics["decode_p10_tps"] < 30:
                    problems.append("decode p10 below 30 tokens/s")
                if baseline is None or metrics["first_content_p95_ms"] > max(3000, baseline["first_content_p95_ms"] * 1.5):
                    problems.append("same-shape B1 first-content bound exceeded or absent")
                if previous_width is not None:
                    previous = measured.get((previous_width, *shape))
                    if previous is None or metrics["aggregate_decode_tps"] < previous["aggregate_decode_tps"] * 1.1:
                        problems.append("less than 10% throughput gain over previous selected width")
                cap = report.get("mixed_prefill_token_cap")
                if cap is not None and width > 1 and cell["arrival_pattern"] == "staggered":
                    prior = cell.get("mixed_prefill_baseline")
                    if (type(cap) is not int or not 128 <= cap <= 512 or not isinstance(prior, dict) or
                            not digest(prior.get("receipt_sha256")) or
                            "effective_mixed_prefill_token_cap" not in prior or
                            (prior["effective_mixed_prefill_token_cap"] is not None and
                             (type(prior["effective_mixed_prefill_token_cap"]) is not int or
                              prior["effective_mixed_prefill_token_cap"] < 0)) or
                            prior["effective_mixed_prefill_token_cap"] == cap or
                            any(not positive(prior.get(k)) for k in METRICS) or
                            not positive(cell.get("mixed_prefill_work_p95_ms")) or
                            cell["mixed_prefill_work_p95_ms"] > 100):
                        problems.append("mixed-prefill promotion requires a matching baseline receipt")
                    elif (metrics["token_gap_p95_ms"] > prior["token_gap_p95_ms"] * .75 or
                          metrics["first_content_p95_ms"] > prior["first_content_p95_ms"] * 1.05 or
                          metrics["aggregate_decode_tps"] < prior["aggregate_decode_tps"] * .95):
                        problems.append("mixed-prefill promotion thresholds failed")
            failures.extend(f"{key}: {problem}" for problem in problems)
        # A larger scheduler cap can still execute every smaller required
        # batch shape. Never skip a failed or unmeasured rung of the ladder.
        if failures and blocked_by_width is None:
            blocked_by_width = width
        result["widths"].append({"width": width, "qualified": not failures, "errors": failures})
        if not failures and (width == 1 or selected):
            values = [measured[(width, *shape)] for shape in required]
            selected.append({"width": width,
                             "decode_p10_tps": min(v["decode_p10_tps"] for v in values),
                             "aggregate_decode_tps": min(v["aggregate_decode_tps"] for v in values),
                             "prefill_tps": min(v["prefill_tps"] for v in values),
                             "first_content_p95_ms": max(v["first_content_p95_ms"] for v in values)})
            previous_width = width
    if selected:
        limit = selected[-1]["width"]
        # Identity cannot carry serving policy or qualification results. Copy
        # only the closed identity contract; derive every other field below.
        profile = {field: identity[field] for field in IDENTITY_FIELDS}
        if identity.get("mtp") is not None:
            profile["mtp"] = identity["mtp"]
        profile.update(max_concurrency=limit, whole_mac_concurrency=limit,
                       qualification_report_sha256=result["receipt_sha256"], batch_curve=selected)
        # B1 has no mixed steps and therefore cannot certify a chunk policy.
        if limit > 1 and report.get("mixed_prefill_token_cap") is not None:
            profile["mixed_prefill_token_cap"] = report["mixed_prefill_token_cap"]
        result.update(qualified=True, profile=profile)
        if report.get("schema_version") == 2 or report.get("deadline_calibration") is not None:
            calibration = evaluate_calibration(
                report.get("deadline_calibration"), result["receipt_sha256"], identity["context_tokens_max"])
            result["deadline_calibration"] = calibration
            if calibration["qualified"]:
                profile["deadline_calibration"] = calibration["calibration"]
            else:
                result.update(qualified=False, profile=None)
                errors.extend(calibration["errors"])
    return result
