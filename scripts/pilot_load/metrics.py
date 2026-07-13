from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Iterable

from .client import TargetRun
from .config import Profile


@dataclass(frozen=True)
class GateFailure:
    gate: str
    actual: float | str
    limit: float | str


def summarize_target(run: TargetRun) -> dict:
    stage_samples: dict[str, list[float]] = {}
    prediction_errors: list[float] = []
    prediction_sources: dict[str, int] = {}
    statuses: dict[str, int] = {}
    transport_errors = 0
    slow_consumers = 0
    for observation in run.observations:
        statuses[str(observation.status)] = statuses.get(str(observation.status), 0) + 1
        transport_errors += observation.error is not None
        slow_consumers += observation.slow_consumer
        for stage, value in observation.stages_ms.items():
            stage_samples.setdefault(stage, []).append(value)
        if observation.prediction_error_ms is not None:
            prediction_errors.append(observation.prediction_error_ms)
            source = observation.prediction_source or "unknown"
            prediction_sources[source] = prediction_sources.get(source, 0) + 1
    return {
        "requests": len(run.observations),
        "elapsed_seconds": run.elapsed_seconds,
        "load_elapsed_seconds": run.load_elapsed_seconds,
        "throughput_rps": run.throughput_rps,
        "statuses": statuses,
        "transport_errors": transport_errors,
        "slow_consumers": slow_consumers,
        "concurrency_levels": list(run.concurrency_levels),
        "cycles": run.cycles,
        "stages_ms": {name: distribution(values) for name, values in sorted(stage_samples.items())},
        "prediction_error_ms": {
            **distribution(prediction_errors),
            "sources": prediction_sources,
            "mean_absolute": (
                sum(abs(value) for value in prediction_errors) / len(prediction_errors)
                if prediction_errors
                else None
            ),
        },
    }


def distribution(values: Iterable[float]) -> dict[str, float | int | None]:
    ordered = sorted(values)
    if not ordered:
        return {"samples": 0, "p50": None, "p95": None, "p99": None, "max": None}
    return {
        "samples": len(ordered),
        "p50": _percentile(ordered, 50),
        "p95": _percentile(ordered, 95),
        "p99": _percentile(ordered, 99),
        "max": ordered[-1],
    }


def evaluate_budgets(profile: Profile, summaries: dict[str, dict]) -> list[GateFailure]:
    failures: list[GateFailure] = []
    for implementation, summary in summaries.items():
        if summary["transport_errors"]:
            failures.append(
                GateFailure(
                    gate=f"{implementation}.transport_errors",
                    actual=summary["transport_errors"],
                    limit=0,
                )
            )
        for stage, budget in profile.stage_budgets_ms.items():
            measured = summary["stages_ms"].get(stage)
            if not measured or measured["samples"] == 0:
                failures.append(
                    GateFailure(
                        gate=f"{implementation}.stage.{stage}.samples",
                        actual=0,
                        limit="at least 1",
                    )
                )
                continue
            for quantile, limit in budget.items():
                minimum_samples = 100 if quantile in {"p95", "p99"} else 1
                if measured["samples"] < minimum_samples:
                    failures.append(
                        GateFailure(
                            gate=f"{implementation}.stage.{stage}.{quantile}.samples",
                            actual=measured["samples"],
                            limit=f"at least {minimum_samples}",
                        )
                    )
                    continue
                actual = measured[quantile]
                if actual is not None and actual > limit:
                    failures.append(
                        GateFailure(
                            gate=f"{implementation}.stage.{stage}.{quantile}",
                            actual=actual,
                            limit=limit,
                        )
                    )
        if (
            profile.require_prediction_samples
            and summary["prediction_error_ms"]["samples"] < 100
        ):
            failures.append(
                GateFailure(
                    gate=f"{implementation}.prediction_error.samples",
                    actual=summary["prediction_error_ms"]["samples"],
                    limit="at least 100",
                )
            )
    return failures


def evaluate_baseline(
    profile: Profile,
    summaries: dict[str, dict],
    baseline: dict | None,
) -> list[GateFailure]:
    if not baseline:
        return []
    failures: list[GateFailure] = []
    baseline_profile = baseline.get("profile")
    if isinstance(baseline_profile, dict) and baseline_profile.get("name") != profile.name:
        return [
            GateFailure(
                gate="baseline.profile",
                actual=baseline_profile.get("name", "missing"),
                limit=profile.name,
            )
        ]
    baseline_targets = baseline.get("targets", {})
    sample_thresholds = baseline.get("sample_thresholds", {})
    for implementation, summary in summaries.items():
        expected = baseline_targets.get(implementation)
        if not isinstance(expected, dict):
            failures.append(
                GateFailure(
                    gate=f"{implementation}.baseline",
                    actual="missing",
                    limit="versioned target baseline",
                )
            )
            continue
        throughput = expected.get("throughput_rps")
        if isinstance(throughput, (int, float)) and not isinstance(throughput, bool) and throughput > 0:
            minimum = throughput * (1 - profile.regression_thresholds["throughput_percent"] / 100)
            if summary["throughput_rps"] < minimum:
                failures.append(
                    GateFailure(
                        gate=f"{implementation}.baseline.throughput_rps",
                        actual=summary["throughput_rps"],
                        limit=minimum,
                    )
                )
        else:
            failures.append(
                GateFailure(
                    gate=f"{implementation}.baseline.throughput_rps",
                    actual="missing",
                    limit="positive numeric baseline",
                )
            )
        expected_stages = expected.get("stages_ms", {})
        for stage in profile.stage_budgets_ms:
            expected_distribution = expected_stages.get(stage)
            if not isinstance(expected_distribution, dict):
                failures.append(
                    GateFailure(
                        gate=f"{implementation}.baseline.{stage}",
                        actual="missing",
                        limit="distribution baseline",
                    )
                )
                continue
            actual_distribution = summary["stages_ms"].get(stage)
            if not actual_distribution:
                failures.append(
                    GateFailure(
                        gate=f"{implementation}.baseline.{stage}.actual",
                        actual="missing",
                        limit="measured distribution",
                    )
                )
                continue
            for quantile in ("p50", "p95", "p99", "max"):
                expected_value = expected_distribution.get(quantile)
                actual_value = actual_distribution.get(quantile)
                minimum_samples = sample_thresholds.get(quantile)
                if (
                    isinstance(minimum_samples, int)
                    and actual_distribution.get("samples", 0) < minimum_samples
                ):
                    failures.append(
                        GateFailure(
                            gate=f"{implementation}.baseline.{stage}.{quantile}.samples",
                            actual=actual_distribution.get("samples", 0),
                            limit=minimum_samples,
                        )
                    )
                if (
                    isinstance(expected_value, bool)
                    or not isinstance(expected_value, (int, float))
                    or actual_value is None
                ):
                    failures.append(
                        GateFailure(
                            gate=f"{implementation}.baseline.{stage}.{quantile}.value",
                            actual="missing",
                            limit="numeric baseline and measurement",
                        )
                    )
                    continue
                maximum = _latency_regression_limit(
                    expected_distribution,
                    quantile,
                    profile.regression_thresholds["latency_percent"],
                )
                if actual_value > maximum:
                    failures.append(
                        GateFailure(
                            gate=f"{implementation}.baseline.{stage}.{quantile}",
                            actual=actual_value,
                            limit=maximum,
                        )
                    )
        expected_prediction = expected.get("prediction_error_ms", {}).get("mean_absolute")
        expected_prediction_distribution = expected.get("prediction_error_ms", {})
        actual_prediction = summary["prediction_error_ms"].get("mean_absolute")
        if isinstance(expected_prediction, (int, float)) and actual_prediction is not None:
            relative_allowance = expected_prediction * (
                profile.regression_thresholds["prediction_error_percent"] / 100
            )
            prediction_p50 = expected_prediction_distribution.get("p50")
            prediction_p99 = expected_prediction_distribution.get("p99")
            observed_spread = (
                max(0.0, prediction_p99 - prediction_p50)
                if isinstance(prediction_p50, (int, float))
                and isinstance(prediction_p99, (int, float))
                else 0.0
            )
            maximum = expected_prediction + max(
                relative_allowance,
                observed_spread * 0.25,
            )
            if actual_prediction > maximum:
                failures.append(
                    GateFailure(
                        gate=f"{implementation}.baseline.prediction_error.mean_absolute",
                        actual=actual_prediction,
                        limit=maximum,
                    )
                )
        elif profile.require_prediction_samples:
            failures.append(
                GateFailure(
                    gate=f"{implementation}.baseline.prediction_error.mean_absolute",
                    actual="missing",
                    limit="numeric baseline and measurement",
                )
            )
    return failures


def _latency_regression_limit(
    distribution: dict,
    quantile: str,
    percent: float,
) -> float:
    expected = distribution[quantile]
    p50 = distribution.get("p50")
    maximum = distribution.get("max")
    observed_spread = (
        max(0.0, maximum - p50)
        if isinstance(p50, (int, float)) and isinstance(maximum, (int, float))
        else 0.0
    )
    spread_factors = {
        "p50": 0.10,
        "p95": 0.50,
        "p99": 0.75,
        "max": 0.0,
    }
    allowance = max(
        expected * percent / 100,
        observed_spread * spread_factors[quantile],
    )
    return expected + allowance


def _percentile(ordered: list[float], percentile: float) -> float:
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * percentile / 100
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction
