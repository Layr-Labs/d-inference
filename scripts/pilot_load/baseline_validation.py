from __future__ import annotations

import re
from typing import Any

from .config import Profile


BASELINE_SCHEMA_VERSION = 2
FIXTURE_SCHEMA_VERSION = 1
MINIMUM_MEASUREMENT_SAMPLES = 100


def validate_measurement(measurement: dict[str, Any], profile: Profile) -> None:
    generated_at = measurement.get("generated_at")
    if not isinstance(generated_at, str) or not generated_at:
        raise ValueError("baseline generated_at provenance is missing")
    source_commit = measurement.get("source_commit")
    if not is_commit(source_commit):
        raise ValueError("baseline source_commit must be a full hexadecimal commit ID")
    source = measurement.get("source")
    if not isinstance(source, dict) or source.get("commit") != source_commit:
        raise ValueError("baseline source provenance does not match source_commit")
    tool = measurement.get("tool")
    if (
        not isinstance(tool, dict)
        or not isinstance(tool.get("name"), str)
        or not tool["name"]
        or not isinstance(tool.get("version"), str)
        or not tool["version"]
        or not is_sha256(tool.get("source_sha256"))
    ):
        raise ValueError("baseline measurement tool provenance is invalid")
    environment = measurement.get("environment")
    if not isinstance(environment, dict) or any(
        not environment.get(field) for field in ("platform", "machine", "kernel_release")
    ):
        raise ValueError("baseline environment provenance is incomplete")
    _validate_execution_environment(measurement.get("execution_environment"))
    _validate_artifacts(
        measurement.get("inputs"),
        "baseline input",
        required={"profiles", "allowed_differences", "oracle"},
    )
    _validate_artifacts(
        measurement.get("executables"),
        "baseline executable",
        required={"go_coordinator", "rust_coordinator", "go_peer", "rust_peer"},
    )
    schemas = measurement.get("schemas")
    if schemas != {
        "report": 1,
        "baseline": BASELINE_SCHEMA_VERSION,
        "fixture": FIXTURE_SCHEMA_VERSION,
    }:
        raise ValueError("baseline schema provenance is invalid")
    _validate_source_report(measurement.get("source_report"))
    _validate_profile(measurement.get("profile"), profile)
    _validate_thresholds(measurement.get("sample_thresholds"))
    targets = measurement.get("targets")
    if not isinstance(targets, dict) or set(targets) != {"go", "rust"}:
        raise ValueError("baseline must contain exactly measured Go and Rust targets")
    for target_name, target in targets.items():
        _validate_target(target_name, target, profile)
    _validate_resources(measurement.get("resources"), profile)


def is_sha256(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def is_commit(value: Any) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40,64}", value) is not None


def _validate_execution_environment(value: Any) -> None:
    pool_max = value.get("database_pool_max") if isinstance(value, dict) else None
    if (
        not isinstance(pool_max, dict)
        or set(pool_max) != {"go", "rust"}
        or any(
            isinstance(number, bool) or not isinstance(number, int) or number <= 0
            for number in pool_max.values()
        )
        or value.get("source_baseline_mode") not in {"capture", "measured"}
    ):
        raise ValueError("baseline execution environment provenance is incomplete")


def _validate_source_report(source_report: Any) -> None:
    if (
        not isinstance(source_report, dict)
        or not is_sha256(source_report.get("sha256"))
        or isinstance(source_report.get("size_bytes"), bool)
        or not isinstance(source_report.get("size_bytes"), int)
        or source_report["size_bytes"] <= 0
    ):
        raise ValueError("baseline source report hash provenance is invalid")


def _validate_profile(value: Any, profile: Profile) -> None:
    if (
        not isinstance(value, dict)
        or value.get("name") != profile.name
        or value.get("seed") != profile.seed
        or value.get("request_count") != profile.request_count
        or value.get("websocket_sessions") != profile.websocket_sessions
        or value.get("concurrency_ramp") != list(profile.concurrency_ramp)
    ):
        raise ValueError("baseline profile provenance does not match configured profile")


def _validate_thresholds(thresholds: Any) -> None:
    if (
        not isinstance(thresholds, dict)
        or set(thresholds) != {"p50", "p95", "p99", "max"}
        or any(
            isinstance(value, bool)
            or not isinstance(value, int)
            or value < MINIMUM_MEASUREMENT_SAMPLES
            for value in thresholds.values()
        )
    ):
        raise ValueError("baseline sample thresholds must all be at least 100")


def _validate_target(target_name: str, target: Any, profile: Profile) -> None:
    if not isinstance(target, dict):
        raise ValueError(f"baseline target {target_name} is invalid")
    if not _positive_number(target.get("throughput_rps")):
        raise ValueError(f"baseline target {target_name} throughput is not observed")
    if (
        isinstance(target.get("requests"), bool)
        or not isinstance(target.get("requests"), int)
        or target["requests"] < MINIMUM_MEASUREMENT_SAMPLES
        or not isinstance(target.get("statuses"), dict)
        or not target["statuses"]
    ):
        raise ValueError(f"baseline target {target_name} request/status samples are incomplete")
    stages = target.get("stages_ms")
    if not isinstance(stages, dict) or not stages:
        raise ValueError(f"baseline target {target_name} stage observations are missing")
    for stage_name, distribution in stages.items():
        _validate_distribution(f"{target_name}.{stage_name}", distribution)
    _reject_ceiling_copies(target_name, stages, profile)
    prediction = target.get("prediction_error_ms")
    if (
        not isinstance(prediction, dict)
        or isinstance(prediction.get("samples"), bool)
        or not isinstance(prediction.get("samples"), int)
        or prediction["samples"] < MINIMUM_MEASUREMENT_SAMPLES
        or not _number(prediction.get("mean_absolute"))
    ):
        raise ValueError(
            f"baseline target {target_name} prediction observations are incomplete"
        )


def _reject_ceiling_copies(
    target_name: str,
    stages: dict[str, Any],
    profile: Profile,
) -> None:
    for stage_name, ceilings in profile.stage_budgets_ms.items():
        distribution = stages.get(stage_name)
        if not isinstance(distribution, dict):
            raise ValueError(
                f"baseline target {target_name} is missing configured stage {stage_name}"
            )
        for quantile, ceiling in ceilings.items():
            if distribution.get(quantile) == ceiling:
                raise ValueError(
                    f"baseline {target_name}.{stage_name}.{quantile} equals its "
                    "absolute budget ceiling instead of an observation"
                )


def _validate_distribution(name: str, distribution: Any) -> None:
    if (
        not isinstance(distribution, dict)
        or isinstance(distribution.get("samples"), bool)
        or not isinstance(distribution.get("samples"), int)
        or distribution["samples"] < MINIMUM_MEASUREMENT_SAMPLES
    ):
        raise ValueError(f"baseline stage {name} requires at least 100 samples")
    values = [distribution.get(key) for key in ("p50", "p95", "p99", "max")]
    if not all(_number(value) for value in values):
        raise ValueError(f"baseline stage {name} quantiles must be numeric observations")
    if not values[0] <= values[1] <= values[2] <= values[3]:
        raise ValueError(f"baseline stage {name} quantiles must be monotonic")


def _validate_resources(resources: Any, profile: Profile) -> None:
    minimum_samples = MINIMUM_MEASUREMENT_SAMPLES if profile.soak else 2
    if (
        not isinstance(resources, dict)
        or isinstance(resources.get("samples"), bool)
        or not isinstance(resources.get("samples"), int)
        or resources["samples"] < minimum_samples
    ):
        raise ValueError(
            f"baseline resource sample count must be at least {minimum_samples}"
        )
    processes = resources.get("processes")
    if not isinstance(processes, dict):
        raise ValueError("baseline process resources are missing")
    for name in ("go-coordinator", "rust-coordinator"):
        process = processes.get(name)
        if not isinstance(process, dict) or any(
            not _number(process.get(metric))
            for metric in ("rss_peak_bytes", "tasks_peak", "fd_peak")
        ):
            raise ValueError(f"baseline process resources are incomplete for {name}")
    for category in ("databases", "mailboxes"):
        values = resources.get(category)
        if not isinstance(values, dict):
            raise ValueError(f"baseline {category} resources are missing")
        for name in ("go", "rust"):
            if not isinstance(values.get(name), dict) or not _number(
                values[name].get("utilization_peak")
            ):
                raise ValueError(
                    f"baseline {category} utilization is incomplete for {name}"
                )


def _validate_artifacts(
    artifacts: Any,
    label: str,
    *,
    required: set[str],
) -> None:
    if not isinstance(artifacts, dict) or not required.issubset(artifacts):
        raise ValueError(f"{label} artifact provenance is incomplete")
    for name in required:
        artifact = artifacts[name]
        if (
            not isinstance(artifact, dict)
            or not isinstance(artifact.get("path"), str)
            or not artifact["path"]
            or not is_sha256(artifact.get("sha256"))
            or isinstance(artifact.get("size_bytes"), bool)
            or not isinstance(artifact.get("size_bytes"), int)
            or artifact["size_bytes"] <= 0
        ):
            raise ValueError(f"{label} artifact provenance is invalid for {name}")


def _number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _positive_number(value: Any) -> bool:
    return _number(value) and value > 0
