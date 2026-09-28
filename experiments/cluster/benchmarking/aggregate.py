"""Pure fixed-study aggregation of supplied, unqualified request measurements.

The adapter owns the loading-excluded interval ending at the first target token.
This module checks supplied records; it does not observe hardware or execution.
"""

from fractions import Fraction
import re

from .specification import make_schedule, read_study


TOKEN_COUNT = 8192
INT63_MAX = 2**63 - 1
MAX_ERROR_BYTES = 4096
_FIXED_FIELDS = frozenset(("token_count", "batch_size", "warmup_count", "measured_runs"))
_MEASUREMENT_FIELDS = frozenset(("elapsed_ns", "prompt_tokens", "generated_tokens", "source_sha256"))


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _fields(value, names, where):
    _require(type(value) is dict and set(value) == set(names), where + ": fields differ")


def _same(actual, expected):
    _require(type(actual) is type(expected), "Schedule type differs from the study")
    if type(expected) is dict:
        _require(set(actual) == set(expected), "Schedule fields differ from the study")
        for key, value in expected.items():
            _same(actual[key], value)
    elif type(expected) is list:
        _require(len(actual) == len(expected), "Schedule count differs from the study")
        for left, right in zip(actual, expected):
            _same(left, right)
    else:
        _require(actual == expected, "Schedule identity or order differs from the study")


def validate_measurement(value):
    """Return detached scalar metadata, refusing even invalid warmup records."""
    _fields(value, _MEASUREMENT_FIELDS, "measurement")
    elapsed = value["elapsed_ns"]
    _require(type(elapsed) is int and 1 <= elapsed <= INT63_MAX, "Invalid elapsed_ns")
    _require(type(value["prompt_tokens"]) is int and value["prompt_tokens"] == TOKEN_COUNT,
             "Measurement must cover exactly 8192 prompt tokens")
    _require(type(value["generated_tokens"]) is int and value["generated_tokens"] == 1,
             "Measurement must end at one generated token")
    source = value["source_sha256"]
    _require(type(source) is str and re.fullmatch(r"[0-9a-f]{64}", source), "Invalid measurement source pin")
    return dict(elapsed_ns=elapsed, prompt_tokens=TOKEN_COUNT, generated_tokens=1, source_sha256=source)


def _error(value):
    _require(type(value) is str and 0 < len(value.encode("utf-8")) <= MAX_ERROR_BYTES
             and "\x00" not in value, "Expected bounded nonempty error text")
    return value


def _outcomes(values, planned):
    _require(type(values) is list and len(values) <= len(planned), "Too many or invalid outcomes")
    result = {}
    for value in values:
        _fields(value, ("request_id", "status", "measurement", "error"), "outcome")
        request = value["request_id"]
        _require(type(request) is str and request in planned and request not in result,
                 "Duplicate or unplanned outcome request ID")
        status = value["status"]
        _require(type(status) is str and status in ("completed", "failed", "skipped"), "Invalid outcome status")
        measurement = None if value["measurement"] is None else validate_measurement(value["measurement"])
        if status == "completed":
            _require(measurement is not None and value["error"] is None, "Completed outcome lacks a clean measurement")
            error = None
        else:
            _require(measurement is None, "Failed or skipped outcome cannot supply a successful measurement")
            error = _error(value["error"])
        result[request] = dict(request_id=request, status=status, measurement=measurement, error=error)
    return result


def _cohort_errors(values, planned):
    _require(type(values) is list and len(values) <= 80, "Too many or invalid cohort errors")
    result = []
    for value in values:
        _fields(value, ("cohort_id", "error"), "cohort error")
        cohort = value["cohort_id"]
        _require(type(cohort) is str and cohort in planned, "Unplanned cohort error ID")
        result.append(dict(cohort_id=cohort, error=_error(value["error"])))
    return result


def _median(values):
    ordered = sorted(values)
    middle = len(ordered) // 2
    return ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2


def _p95(values):
    # Nearest rank: ceil(0.95*n), indexed from one; never interpolate a tail.
    return sorted(values)[(95 * len(values) + 99) // 100 - 1] if values else None


def _counts(statuses):
    return dict(planned=len(statuses), **{status: statuses.count(status)
                for status in ("completed", "failed", "skipped", "missing")})


def _cohort(cohort, outcomes, errors):
    requests = cohort["requests"]
    warmup = outcomes.get(requests[0]["request_id"])
    samples, rates, elapsed = [], [], []
    for request in requests[1:]:
        outcome = outcomes.get(request["request_id"])
        measurement = outcome["measurement"] if outcome is not None else None
        rate = Fraction(TOKEN_COUNT * 10**9, measurement["elapsed_ns"]) if measurement else None
        samples.append(dict(request_id=request["request_id"], iteration=request["iteration"],
                            status=outcome["status"] if outcome else "missing",
                            elapsed_ns=measurement["elapsed_ns"] if measurement else None,
                            tps=float(rate) if rate is not None else None,
                            source_sha256=measurement["source_sha256"] if measurement else None,
                            error=outcome["error"] if outcome else None))
        if rate is not None:
            rates.append(rate)
            elapsed.append(measurement["elapsed_ns"])
    warmup_status = warmup["status"] if warmup else "missing"
    failures = [entry["error"] for entry in errors if entry["cohort_id"] == cohort["cohort_id"]]
    complete = warmup_status == "completed" and len(rates) == 3 and not failures
    median_rate = _median(rates) if complete else None
    return dict(cohort_id=cohort["cohort_id"], prompt_id=cohort["prompt_id"],
                prompt_sha256=cohort["prompt_sha256"], cohort_status="complete" if complete else "incomplete",
                warmup=dict(request_id=requests[0]["request_id"], status=warmup_status,
                            error=warmup["error"] if warmup else None),
                measured_counts=_counts([sample["status"] for sample in samples]), measured_samples=samples,
                median_tps=float(median_rate) if median_rate is not None else None,
                median_latency_ns=sorted(elapsed)[1] if complete else None,
                p95_latency_ns=_p95(elapsed), p95_sample_count=len(elapsed), cohort_errors=failures), median_rate


def summarize(study, schedule, outcomes, cohort_errors):
    """Summarize exactly ten paired prompts; any incomplete cohort withholds TPS.

    Individual rates and threshold comparisons use exact rational arithmetic;
    reported TPS/speedups are JSON floats, with original integer samples retained.
    Warmup measurements are validated but entirely excluded from statistics.
    """
    expected = make_schedule(study)
    _same(schedule, expected)
    checked = read_study({key: value for key, value in study.items() if key not in _FIXED_FIELDS})
    planned = {request["request_id"] for cohort in expected for request in cohort["requests"]}
    parsed = _outcomes(outcomes, planned)
    errors = _cohort_errors(cohort_errors, {cohort["cohort_id"] for cohort in expected})
    cohorts = {(row["condition_id"], row["prompt_id"]): _cohort(row, parsed, errors) for row in expected}
    complete = all(row[0]["cohort_status"] == "complete" for row in cohorts.values())
    conditions, aggregates = [], {}
    for condition in checked["conditions"]:
        rows = [cohorts[condition["id"], prompt["id"]] for prompt in checked["prompts"]]
        samples = [sample for row, _ in rows for sample in row["measured_samples"]]
        elapsed = [sample["elapsed_ns"] for sample in samples if sample["status"] == "completed"]
        rate = _median([median for _, median in rows]) if complete else None
        aggregates[condition["role"]] = rate
        conditions.append(dict(condition, aggregate_status="complete" if complete else "incomplete",
            median_of_prompt_medians_tps=float(rate) if rate is not None else None,
            supplied_result_target_met=rate >= 800 if complete else None,
            supplied_result_stretch_met=rate >= 1000 if complete else None,
            measured_counts=_counts([sample["status"] for sample in samples]),
            warmup_counts=_counts([row["warmup"]["status"] for row, _ in rows]),
            measured_elapsed_ns=elapsed, p95_latency_ns=_p95(elapsed), p95_sample_count=len(elapsed),
            per_prompt=[row for row, _ in rows]))
    solo, distributed = [condition["id"] for condition in checked["conditions"]]
    pairs, ratios = [], []
    for prompt in checked["prompts"]:
        left, right = cohorts[solo, prompt["id"]][1], cohorts[distributed, prompt["id"]][1]
        ratio = right / left if left is not None and right is not None else None
        if ratio is not None:
            ratios.append(ratio)
        pairs.append(dict(prompt_id=prompt["id"], distributed_over_solo_speedup=float(ratio) if ratio is not None else None))
    statuses = [parsed[request]["status"] if request in parsed else "missing" for request in planned]
    return dict(schema="cluster_prefill_study_summary_v1", study_id=checked["study_id"],
                aggregate_status="complete" if complete else "incomplete", request_counts=_counts(statuses),
                conditions=conditions, paired_prompt_speedups=pairs,
                median_paired_prompt_speedup=float(_median(ratios)) if complete else None,
                aggregate_distributed_over_solo_speedup=float(aggregates["distributed"] / aggregates["solo"]) if complete else None,
                cohort_error_count=len(errors), cohort_errors=errors, target_tps=800, stretch_tps=1000,
                warmups_included_in_statistics=False, measurement_interval_attested=False,
                hardware_identity_verified=False, representative_prompts_established=False,
                performance_qualification=False, runtime_admission=False)
