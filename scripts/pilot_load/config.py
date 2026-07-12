from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any


QUANTILES = ("p50", "p95", "p99", "max")
RESOURCE_BOUNDS = {
    "rss_growth_bytes",
    "tasks_growth",
    "fd_growth",
    "mailbox_utilization",
    "database_pool_utilization",
}
REGRESSION_THRESHOLDS = {
    "latency_percent",
    "throughput_percent",
    "prediction_error_percent",
    "resource_percent",
}


@dataclass(frozen=True)
class Profile:
    name: str
    description: str
    seed: int
    duration_seconds: int
    soak: bool
    base_requests: int
    request_multiplier: int
    chunk_multiplier: int
    websocket_sessions: int
    concurrency_ramp: tuple[int, ...]
    slow_consumer_fraction: float
    slow_consumer_delay_ms: int
    required_scenarios: tuple[str, ...]
    stage_budgets_ms: dict[str, dict[str, float]]
    resource_bounds: dict[str, float]
    regression_thresholds: dict[str, float]
    require_billing_snapshot: bool
    require_prediction_samples: bool
    require_resource_counters: bool
    require_peer_counters: bool
    require_regression_baseline: bool = True

    @property
    def request_count(self) -> int:
        return self.base_requests * self.request_multiplier


@dataclass(frozen=True)
class DifferenceRule:
    id: str
    scenario: str
    path: str
    action: str
    reason: str
    go_minus_rust: float | None = None


def load_profile(path: Path, name: str) -> Profile:
    document = _load_schema(path)
    profiles = document.get("profiles")
    if not isinstance(profiles, dict) or name not in profiles:
        raise ValueError(f"profile {name!r} is not defined in {path}")
    raw = profiles[name]
    if not isinstance(raw, dict):
        raise ValueError(f"profile {name!r} must be an object")
    profile = Profile(
        name=name,
        description=_string(raw, "description"),
        seed=_positive_int(raw, "seed"),
        duration_seconds=_positive_int(raw, "duration_seconds"),
        soak=_bool(raw, "soak"),
        base_requests=_positive_int(raw, "base_requests"),
        request_multiplier=_positive_int(raw, "request_multiplier"),
        chunk_multiplier=_positive_int(raw, "chunk_multiplier"),
        websocket_sessions=_positive_int(raw, "websocket_sessions"),
        concurrency_ramp=tuple(_positive_int_value(value, "concurrency_ramp") for value in _list(raw, "concurrency_ramp")),
        slow_consumer_fraction=_bounded_float(raw, "slow_consumer_fraction", 0, 1),
        slow_consumer_delay_ms=_nonnegative_int(raw, "slow_consumer_delay_ms"),
        required_scenarios=tuple(_string_value(value, "required_scenarios") for value in _list(raw, "required_scenarios")),
        stage_budgets_ms=_stage_budgets(raw),
        resource_bounds=_number_map(raw, "resource_bounds"),
        regression_thresholds=_number_map(raw, "regression_thresholds"),
        require_billing_snapshot=_bool(raw, "require_billing_snapshot"),
        require_prediction_samples=_bool(raw, "require_prediction_samples"),
        require_resource_counters=_bool(raw, "require_resource_counters"),
        require_peer_counters=_bool(raw, "require_peer_counters"),
        require_regression_baseline=_bool(raw, "require_regression_baseline"),
    )
    if sorted(set(profile.concurrency_ramp)) != list(profile.concurrency_ramp):
        raise ValueError("concurrency_ramp must be strictly increasing and unique")
    if len(set(profile.required_scenarios)) != len(profile.required_scenarios):
        raise ValueError("required_scenarios contains duplicates")
    _require_exact_keys(profile.resource_bounds, RESOURCE_BOUNDS, "resource_bounds")
    _require_exact_keys(
        profile.regression_thresholds,
        REGRESSION_THRESHOLDS,
        "regression_thresholds",
    )
    return profile


def load_difference_rules(path: Path) -> tuple[DifferenceRule, ...]:
    document = _load_schema(path)
    raw_rules = document.get("rules")
    if not isinstance(raw_rules, list):
        raise ValueError("allowed-difference manifest requires a rules array")
    rules: list[DifferenceRule] = []
    seen: set[str] = set()
    for raw in raw_rules:
        if not isinstance(raw, dict):
            raise ValueError("every allowed-difference rule must be an object")
        rule = DifferenceRule(
            id=_string(raw, "id"),
            scenario=_string(raw, "scenario"),
            path=_string(raw, "path"),
            action=_string(raw, "action"),
            reason=_string(raw, "reason"),
            go_minus_rust=_optional_number(raw, "go_minus_rust"),
        )
        if rule.id in seen:
            raise ValueError(f"duplicate allowed-difference rule {rule.id!r}")
        if rule.action not in {"ignore_value", "same_type", "presence", "numeric_delta"}:
            raise ValueError(f"rule {rule.id!r} has unsupported action {rule.action!r}")
        if (rule.action == "numeric_delta") != (rule.go_minus_rust is not None):
            raise ValueError(
                f"rule {rule.id!r} must define go_minus_rust only for numeric_delta"
            )
        seen.add(rule.id)
        rules.append(rule)
    return tuple(rules)


def _load_schema(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        document = json.load(handle)
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        raise ValueError(f"{path} must use schema_version 1")
    return document


def _stage_budgets(raw: dict[str, Any]) -> dict[str, dict[str, float]]:
    budgets = raw.get("stage_budgets_ms")
    if not isinstance(budgets, dict) or not budgets:
        raise ValueError("stage_budgets_ms must be a nonempty object")
    result: dict[str, dict[str, float]] = {}
    for stage, values in budgets.items():
        if not isinstance(stage, str) or not stage or not isinstance(values, dict):
            raise ValueError("invalid stage budget")
        missing = set(QUANTILES) - values.keys()
        if missing:
            raise ValueError(f"stage {stage!r} is missing budgets: {sorted(missing)}")
        parsed = {quantile: _positive_number(values[quantile], f"{stage}.{quantile}") for quantile in QUANTILES}
        if not (parsed["p50"] <= parsed["p95"] <= parsed["p99"] <= parsed["max"]):
            raise ValueError(f"stage {stage!r} budgets must be monotonic")
        result[stage] = parsed
    return result


def _number_map(raw: dict[str, Any], key: str) -> dict[str, float]:
    values = raw.get(key)
    if not isinstance(values, dict) or not values:
        raise ValueError(f"{key} must be a nonempty object")
    return {str(name): _positive_number(value, f"{key}.{name}") for name, value in values.items()}


def _require_exact_keys(values: dict[str, float], expected: set[str], name: str) -> None:
    actual = set(values)
    if actual != expected:
        raise ValueError(
            f"{name} keys must be {sorted(expected)}; "
            f"missing={sorted(expected - actual)}, unknown={sorted(actual - expected)}"
        )


def _positive_number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or value <= 0:
        raise ValueError(f"{name} must be positive")
    return float(value)


def _optional_number(raw: dict[str, Any], key: str) -> float | None:
    if key not in raw:
        return None
    value = raw[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{key} must be numeric")
    return float(value)


def _positive_int(raw: dict[str, Any], key: str) -> int:
    return _positive_int_value(raw.get(key), key)


def _positive_int_value(value: Any, key: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{key} must contain positive integers")
    return value


def _nonnegative_int(raw: dict[str, Any], key: str) -> int:
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError(f"{key} must be a nonnegative integer")
    return value


def _bounded_float(raw: dict[str, Any], key: str, minimum: float, maximum: float) -> float:
    value = raw.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not minimum <= value <= maximum:
        raise ValueError(f"{key} must be between {minimum} and {maximum}")
    return float(value)


def _string(raw: dict[str, Any], key: str) -> str:
    return _string_value(raw.get(key), key)


def _string_value(value: Any, key: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"{key} must contain nonempty strings")
    return value


def _list(raw: dict[str, Any], key: str) -> list[Any]:
    value = raw.get(key)
    if not isinstance(value, list) or not value:
        raise ValueError(f"{key} must be a nonempty array")
    return value


def _bool(raw: dict[str, Any], key: str) -> bool:
    value = raw.get(key)
    if not isinstance(value, bool):
        raise ValueError(f"{key} must be a boolean")
    return value
