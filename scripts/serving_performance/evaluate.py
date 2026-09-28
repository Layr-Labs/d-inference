"""Evaluate raw receipts; missing evidence fails closed and cannot expand service."""
import hashlib
import json

from .matrix import CHECKS, MIN_SAMPLES, cell_key, digest, identity_errors, positive, shapes, widths

METRICS = ("decode_p10_tps", "aggregate_decode_tps", "prefill_tps",
           "first_content_p95_ms", "token_gap_p95_ms")


def measure(cell, identity):
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
        if sample.get("mtp_active") is not False or sample.get("runtime_policy_overrides") != {}:
            errors.append("initial runtime revision requires measured plain-target execution without policy overrides")
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
    if cap is not None and (type(cap) is not int or not 128 <= cap <= 512):
        errors.append("mixed_prefill_token_cap must be an integer in 128...512")
    serving_sets = report.get("serving_sets", [])
    if (not isinstance(serving_sets, list) or [] not in serving_sets or
            not any(isinstance(s, list) and s for s in serving_sets) or
            any(not isinstance(s, list) or any(not isinstance(m, str) or not m for m in s)
                or len(set(s)) != len(s) for s in serving_sets)):
        errors.append("serving_sets must include isolated and explicit competing-model cases")
    if report.get("schema_version") != 1:
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
    for width in widths(identity):
        failures = []
        for shape in required:
            key = (width, *shape)
            cell = cells.get(key)
            if cell is None:
                failures.append(f"missing {key}")
                continue
            metrics, problems = measure(cell, identity)
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
                            any(not positive(prior.get(k)) for k in METRICS) or
                            not positive(cell.get("mixed_prefill_work_p95_ms")) or
                            cell["mixed_prefill_work_p95_ms"] > 100):
                        problems.append("mixed-prefill promotion requires a matching baseline receipt")
                    elif (metrics["token_gap_p95_ms"] > prior["token_gap_p95_ms"] * .75 or
                          metrics["first_content_p95_ms"] > prior["first_content_p95_ms"] * 1.05 or
                          metrics["aggregate_decode_tps"] < prior["aggregate_decode_tps"] * .95):
                        problems.append("mixed-prefill promotion thresholds failed")
            failures.extend(f"{key}: {problem}" for problem in problems)
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
        profile = dict(identity, max_concurrency=limit, whole_mac_concurrency=limit,
                       qualification_report_sha256=result["receipt_sha256"], batch_curve=selected)
        # B1 has no mixed steps and therefore cannot certify a chunk policy.
        if limit > 1 and report.get("mixed_prefill_token_cap") is not None:
            profile["mixed_prefill_token_cap"] = report["mixed_prefill_token_cap"]
        result.update(qualified=True, profile=profile)
    return result
