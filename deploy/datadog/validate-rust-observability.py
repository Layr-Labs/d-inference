#!/usr/bin/env python3
"""Validate Rust coordinator Datadog JSON, allowlist, and cardinality."""

from __future__ import annotations

import json
import pathlib
import re
import sys
from collections.abc import Iterable
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[2]
DATADOG = ROOT / "deploy" / "datadog"
ALLOWLIST_PATH = DATADOG / "rust-metrics-allowlist.json"
SOURCE_PATH = (
    ROOT / "coordinator-rs" / "crates" / "server" / "src" / "telemetry" / "datadog.rs"
)
TAG_SOURCE_PATH = (
    ROOT
    / "coordinator-rs"
    / "crates"
    / "server"
    / "src"
    / "telemetry"
    / "datadog"
    / "tags.rs"
)
DASHBOARDS = [
    DATADOG / "rust-migration-dashboard-dev.json",
    DATADOG / "rust-migration-dashboard-prod.json",
]
MONITORS_PATH = DATADOG / "rust-migration-monitors.json"
STARTUP_PATH = ROOT / "deploy" / "gcp" / "vm-startup.sh"
METRIC_PATTERN = re.compile(r"\bd_inference\.rust\.[a-z0-9_.]+")
PERCENTILE_METRIC_PATTERN = re.compile(
    r"^(?P<base>d_inference\.rust\.[a-z0-9_.]+)\.(?P<percentile>95|99)percentile$"
)
GROUP_PATTERN = re.compile(r"\bby\s*\{([^}]*)\}")
TAG_FILTER_PATTERN = re.compile(r"(?:^|[, ])([a-z][a-z0-9_]*)\s*(?::|IN\s*\()")
FILTER_BLOCK_PATTERN = re.compile(r"(?<!by\s)\{([^}]*)\}")


class ValidationError(Exception):
    pass


def load_json(path: pathlib.Path) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ValidationError(f"{path}: duplicate JSON key {key!r}")
            result[key] = value
        return result

    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=reject_duplicates)
    except (OSError, json.JSONDecodeError) as error:
        raise ValidationError(f"{path}: invalid JSON: {error}") from error


def validate_source_tag_values(key: str, source: pathlib.Path) -> None:
    payload = load_json(source)
    if key != "route" or not isinstance(payload, dict):
        raise ValidationError(f"tag {key!r} uses an unsupported source catalog")
    routes = payload.get("routes")
    if not isinstance(routes, list):
        raise ValidationError(f"tag {key!r} source has no route catalog")
    values = {"other", "unmatched"}
    for route in routes:
        if not isinstance(route, dict) or not isinstance(route.get("path"), str):
            raise ValidationError(f"tag {key!r} source contains an invalid route")
        value = route["path"].replace("{", ":").replace("}", "")
        if (
            not value
            or len(value.encode("utf-8")) > 64
            or re.fullmatch(r"[A-Za-z0-9_./:-]+", value) is None
        ):
            raise ValidationError(f"tag {key!r} source contains unsafe value {value!r}")
        values.add(value)
    if len(values) > 128:
        raise ValidationError(
            f"tag {key!r} source exceeds its 128-value cardinality bound"
        )


def strings(value: Any) -> Iterable[str]:
    if isinstance(value, str):
        yield value
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)


def query_strings(value: Any) -> Iterable[str]:
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"q", "query"} and isinstance(item, str):
                yield item
            yield from query_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from query_strings(item)


def validate_allowlist(
    payload: Any,
) -> tuple[set[str], dict[str, set[str]], set[str], dict[str, str]]:
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ValidationError("allowlist schema_version must be 1")
    metrics = payload.get("metrics")
    tag_values = payload.get("tag_values")
    forbidden = payload.get("forbidden_tag_keys")
    if not isinstance(metrics, dict) or not metrics:
        raise ValidationError("allowlist metrics must be a nonempty object")
    if not isinstance(tag_values, dict) or not tag_values:
        raise ValidationError("allowlist tag_values must be a nonempty object")
    if not isinstance(forbidden, list) or not all(isinstance(item, str) for item in forbidden):
        raise ValidationError("allowlist forbidden_tag_keys must be a string array")
    forbidden_set = set(forbidden)
    if len(forbidden_set) != len(forbidden):
        raise ValidationError("allowlist forbidden_tag_keys contains duplicates")

    allowed_tags = set(tag_values)
    if allowed_tags & forbidden_set:
        raise ValidationError("allowlist declares a forbidden tag key")
    for key, values in tag_values.items():
        if isinstance(values, list):
            if not values or len(values) > 64:
                raise ValidationError(f"tag {key!r} must define 1..64 bounded values")
            if not all(isinstance(item, str) and item for item in values):
                raise ValidationError(f"tag {key!r} contains an invalid value")
            if len(set(values)) != len(values):
                raise ValidationError(f"tag {key!r} contains duplicate values")
            if "other" not in values:
                raise ValidationError(f"tag {key!r} must reserve the collapse value 'other'")
        elif isinstance(values, dict):
            if set(values) != {"source"} or not isinstance(values["source"], str):
                raise ValidationError(f"tag {key!r} has an unbounded dynamic definition")
            source = ROOT / values["source"]
            if not source.is_file():
                raise ValidationError(f"tag {key!r} source does not exist: {source}")
            validate_source_tag_values(key, source)
        else:
            raise ValidationError(f"tag {key!r} has no cardinality bound")

    metric_tags: dict[str, set[str]] = {}
    metric_kinds: dict[str, str] = {}
    for metric, definition in metrics.items():
        if not isinstance(metric, str) or not metric.startswith(payload["metric_prefix"]):
            raise ValidationError(f"metric {metric!r} is outside the Rust prefix")
        if not isinstance(definition, dict) or definition.get("kind") not in {
            "counter",
            "gauge",
            "histogram",
        }:
            raise ValidationError(f"metric {metric!r} has an invalid kind")
        tags = definition.get("tags")
        if not isinstance(tags, list) or not all(isinstance(tag, str) for tag in tags):
            raise ValidationError(f"metric {metric!r} tags must be a string array")
        if tags != sorted(set(tags)):
            raise ValidationError(f"metric {metric!r} tags must be sorted and unique")
        unknown = set(tags) - allowed_tags
        if unknown:
            raise ValidationError(f"metric {metric!r} has unknown tags: {sorted(unknown)}")
        if set(tags) & forbidden_set:
            raise ValidationError(f"metric {metric!r} uses a forbidden tag")
        metric_tags[metric] = set(tags)
        metric_kinds[metric] = definition["kind"]
    return set(metrics), metric_tags, forbidden_set, metric_kinds


def validate_rust_catalog(metrics: set[str], tags: set[str], forbidden: set[str]) -> None:
    source = SOURCE_PATH.read_text(encoding="utf-8")
    tag_source = TAG_SOURCE_PATH.read_text(encoding="utf-8")
    catalog = set(METRIC_PATTERN.findall(source))
    if catalog != metrics:
        raise ValidationError(
            "Rust metric catalog differs from allowlist: "
            f"missing={sorted(catalog - metrics)} extra={sorted(metrics - catalog)}"
        )
    tag_impl = tag_source.split("impl TagKey", 1)[1].split("/// One sanitized", 1)[0]
    rust_tags = set(re.findall(r'Self::[A-Za-z]+ => "([a-z_]+)"', tag_impl))
    if rust_tags != tags:
        raise ValidationError(
            "Rust tag catalog differs from allowlist: "
            f"missing={sorted(rust_tags - tags)} extra={sorted(tags - rust_tags)}"
        )
    if rust_tags & forbidden:
        raise ValidationError("Rust TagKey exposes a forbidden high-cardinality dimension")
    if re.search(r"\b(?:TODO|FIXME)\b", source + tag_source):
        raise ValidationError("Rust Datadog bridge contains an unfinished marker")


def validate_histogram_deployment(metric_kinds: dict[str, str]) -> None:
    expected = {
        "d_inference.rust.http.stage.duration_ms",
        "d_inference.rust.writer.queue.bytes",
        "d_inference.rust.writer.queue.items",
    }
    actual = {
        metric for metric, kind in metric_kinds.items() if kind == "histogram"
    }
    if actual != expected:
        raise ValidationError(
            "histogram metric catalog differs from deployable percentile contract: "
            f"missing={sorted(expected - actual)} extra={sorted(actual - expected)}"
        )
    source = SOURCE_PATH.read_text(encoding="utf-8")
    if 'MetricKind::Histogram => "h"' not in source or "MetricKind::Distribution" in source:
        raise ValidationError("Rust histogram catalog is incompatible with DogStatsD wire types")
    startup = STARTUP_PATH.read_text(encoding="utf-8")
    for setting in [
        "histogram_aggregates:",
        "histogram_percentiles:",
        "  - 0.95",
        "  - 0.99",
    ]:
        if setting not in startup:
            raise ValidationError(
                f"Datadog Agent histogram configuration is missing {setting!r}"
            )


def validate_queries(
    payload: Any,
    metrics: set[str],
    metric_tags: dict[str, set[str]],
    metric_kinds: dict[str, str],
    forbidden: set[str],
    path: pathlib.Path,
) -> set[str]:
    referenced: set[str] = set()
    infrastructure_tags = {"env", "git_commit", "host", "service", "version"}
    for query in query_strings(payload):
        raw_query_metrics = set(METRIC_PATTERN.findall(query))
        query_metrics: set[str] = set()
        unknown_metrics: set[str] = set()
        for raw_metric in raw_query_metrics:
            if raw_metric in metrics:
                query_metrics.add(raw_metric)
                continue
            percentile = PERCENTILE_METRIC_PATTERN.fullmatch(raw_metric)
            if percentile is None or percentile["base"] not in metrics:
                unknown_metrics.add(raw_metric)
                continue
            base = percentile["base"]
            if metric_kinds[base] != "histogram":
                raise ValidationError(
                    f"{path}: derived percentile {raw_metric!r} requires a histogram metric"
                )
            query_metrics.add(base)
        if unknown_metrics:
            raise ValidationError(f"{path}: unknown Rust metrics {sorted(unknown_metrics)}")
        if query_metrics and re.search(r"(?:percentile\s*\(|\bp(?:95|99):)", query):
            raise ValidationError(
                f"{path}: histogram percentiles must query the Agent-derived "
                ".95percentile/.99percentile metric"
            )
        referenced.update(query_metrics)
        grouping_tags = {
            tag.strip()
            for group in GROUP_PATTERN.findall(query)
            for tag in group.split(",")
            if tag.strip()
        }
        filter_tags = {
            tag
            for block in FILTER_BLOCK_PATTERN.findall(query)
            for tag in TAG_FILTER_PATTERN.findall(block)
        }
        query_tags = grouping_tags | filter_tags
        if query_tags & forbidden:
            raise ValidationError(
                f"{path}: query uses forbidden tags {sorted(query_tags & forbidden)}"
            )
        if query_metrics:
            allowed = infrastructure_tags | set.intersection(
                *(metric_tags[metric] for metric in query_metrics)
            )
            invalid = query_tags - allowed
            if invalid:
                raise ValidationError(
                    f"{path}: query tags {sorted(invalid)} are not allowed for "
                    f"{sorted(query_metrics)}"
                )
    return referenced


def validate_dashboards(
    metrics: set[str],
    metric_tags: dict[str, set[str]],
    metric_kinds: dict[str, str],
    forbidden: set[str],
) -> set[str]:
    referenced: set[str] = set()
    expectations = {
        "rust-migration-dashboard-dev.json": "development",
        "rust-migration-dashboard-prod.json": "production",
    }
    for path in DASHBOARDS:
        payload = load_json(path)
        if not isinstance(payload, dict) or payload.get("layout_type") != "ordered":
            raise ValidationError(f"{path}: dashboard must use ordered layout")
        if not isinstance(payload.get("widgets"), list) or not payload["widgets"]:
            raise ValidationError(f"{path}: dashboard has no widgets")
        variables = {
            item.get("name"): item.get("default")
            for item in payload.get("template_variables", [])
            if isinstance(item, dict)
        }
        if variables.get("env") != expectations[path.name]:
            raise ValidationError(f"{path}: wrong env template default")
        if variables.get("service") != "d-inference-coordinator":
            raise ValidationError(f"{path}: wrong service template default")
        referenced |= validate_queries(
            payload, metrics, metric_tags, metric_kinds, forbidden, path
        )
    return referenced


def validate_monitors(
    metrics: set[str],
    metric_tags: dict[str, set[str]],
    metric_kinds: dict[str, str],
    forbidden: set[str],
) -> set[str]:
    monitors = load_json(MONITORS_PATH)
    if not isinstance(monitors, list) or not monitors:
        raise ValidationError("monitor definitions must be a nonempty array")
    names: list[str] = []
    periodic_freshness_metrics = {
        "d_inference.rust.jobs.age_seconds",
        "d_inference.rust.ownership.healthy",
        "d_inference.rust.rollback_guard",
        "d_inference.rust.schema.checksum_valid",
    }
    for monitor in monitors:
        if not isinstance(monitor, dict):
            raise ValidationError("monitor entry must be an object")
        if monitor.get("type") != "query alert":
            raise ValidationError(f"monitor {monitor.get('name')!r} must be a query alert")
        name = monitor.get("name")
        query = monitor.get("query")
        options = monitor.get("options")
        if not isinstance(name, str) or not isinstance(query, str):
            raise ValidationError("monitor name and query must be strings")
        if "env IN (development,production)" not in query:
            raise ValidationError(f"monitor {name!r} does not cover dev and prod")
        if not isinstance(options, dict) or not isinstance(options.get("thresholds"), dict):
            raise ValidationError(f"monitor {name!r} has no thresholds")
        if not all(isinstance(value, (int, float)) for value in options["thresholds"].values()):
            raise ValidationError(f"monitor {name!r} has a nonnumeric threshold")
        for label, suffix in [("p95", ".95percentile"), ("p99", ".99percentile")]:
            if label in name.lower():
                if suffix not in query:
                    raise ValidationError(
                        f"monitor {name!r} does not query its generated {label} metric"
                    )
                if options.get("notify_no_data") is not True or not isinstance(
                    options.get("no_data_timeframe"), (int, float)
                ):
                    raise ValidationError(
                        f"monitor {name!r} must alert when its percentile is absent"
                    )
        if periodic_freshness_metrics & set(METRIC_PATTERN.findall(query)):
            if options.get("notify_no_data") is not True or not isinstance(
                options.get("no_data_timeframe"), (int, float)
            ):
                raise ValidationError(
                    f"monitor {name!r} must distinguish process absence from "
                    "periodically reported health"
                )
        names.append(name.lower())
    if len(names) != len(set(names)):
        raise ValidationError("monitor names must be unique")

    required = [
        "availability",
        "writer queue saturation",
        "writer queue depth",
        "stuck durable",
        "trust regression",
        "ownership loss",
        "split-brain",
        "migration checksum",
        "below version floor",
        "stripe external",
        "rollback guard",
    ]
    required.extend(f"{stage} {percentile}" for stage in [
        "parse",
        "reserve",
        "prepare",
        "start",
        "ttft",
        "chunk",
        "settle",
    ] for percentile in ["p95", "p99"])
    for phrase in required:
        if not any(phrase in name for name in names):
            raise ValidationError(f"monitor coverage is missing {phrase!r}")
    return validate_queries(
        monitors, metrics, metric_tags, metric_kinds, forbidden, MONITORS_PATH
    )


def main() -> int:
    try:
        allowlist = load_json(ALLOWLIST_PATH)
        metrics, metric_tags, forbidden, metric_kinds = validate_allowlist(allowlist)
        tags = set(allowlist["tag_values"])
        validate_rust_catalog(metrics, tags, forbidden)
        validate_histogram_deployment(metric_kinds)
        referenced = validate_dashboards(metrics, metric_tags, metric_kinds, forbidden)
        referenced |= validate_monitors(metrics, metric_tags, metric_kinds, forbidden)
        missing = metrics - referenced
        if missing:
            raise ValidationError(
                f"dashboard/monitor coverage is missing metrics: {sorted(missing)}"
            )
        for path in [ALLOWLIST_PATH, *DASHBOARDS, MONITORS_PATH]:
            if re.search(r"\b(?:TODO|FIXME)\b", path.read_text(encoding="utf-8")):
                raise ValidationError(f"{path}: unfinished marker")
    except (ValidationError, OSError, re.error) as error:
        print(f"rust observability validation failed: {error}", file=sys.stderr)
        return 1
    print(
        f"rust observability validation passed: "
        f"{len(metrics)} metrics, {len(tags)} tag keys"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
