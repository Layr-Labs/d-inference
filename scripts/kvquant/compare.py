#!/usr/bin/env python3
"""Compare KV quant benchmark JSON reports against threshold JSON.

Reports may expose metrics either under a top-level `metrics` object or at the
root. Threshold paths are matched by key name, with underscore and hyphen
variants accepted to make early report emitters easier to iterate on.
"""

from __future__ import annotations

import argparse
import copy
import json
import math
import sys
from pathlib import Path
from typing import Any, Iterable


MISSING = object()


def load_json_or_jsonl(path: Path) -> list[dict[str, Any]]:
    text = path.read_text(encoding="utf-8")
    if path.suffix == ".jsonl":
        items = []
        for line_number, line in enumerate(text.splitlines(), start=1):
            stripped = line.strip()
            if not stripped:
                continue
            data = json.loads(stripped)
            if not isinstance(data, dict):
                raise ValueError(f"{path}:{line_number}: expected object")
            items.append(data)
        return items

    data = json.loads(text)
    if isinstance(data, list):
        return require_dicts(data, path)
    if isinstance(data, dict):
        for key in ("reports", "results", "runs"):
            value = data.get(key)
            if isinstance(value, list):
                return require_dicts(value, path)
        return [data]
    raise ValueError(f"{path}: expected JSON object, array, or JSONL objects")


def require_dicts(items: list[Any], path: Path) -> list[dict[str, Any]]:
    reports = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise ValueError(f"{path}[{index}]: expected object")
        reports.append(item)
    return reports


def deep_merge(base: dict[str, Any], override: dict[str, Any]) -> dict[str, Any]:
    merged = copy.deepcopy(base)
    for key, value in override.items():
        if isinstance(value, dict) and isinstance(merged.get(key), dict):
            merged[key] = deep_merge(merged[key], value)
        else:
            merged[key] = copy.deepcopy(value)
    return merged


def threshold_leaf(value: Any) -> bool:
    return isinstance(value, dict) and ("min" in value or "max" in value)


def iter_thresholds(tree: dict[str, Any], prefix: tuple[str, ...] = ()) -> Iterable[tuple[tuple[str, ...], dict[str, Any]]]:
    for key, value in tree.items():
        path = prefix + (key,)
        if threshold_leaf(value):
            yield path, value
        elif isinstance(value, dict):
            yield from iter_thresholds(value, path)


def key_variants(key: str) -> tuple[str, ...]:
    variants = [key]
    if "_" in key:
        variants.append(key.replace("_", "-"))
    if "-" in key:
        variants.append(key.replace("-", "_"))
    return tuple(dict.fromkeys(variants))


def nested_get(data: Any, path: tuple[str, ...]) -> Any:
    current = data
    for key in path:
        if not isinstance(current, dict):
            return MISSING
        found = MISSING
        for variant in key_variants(key):
            if variant in current:
                found = current[variant]
                break
        if found is MISSING:
            return MISSING
        current = found
    return current


def metric_value(report: dict[str, Any], path: tuple[str, ...]) -> Any:
    dotted = ".".join(path)
    for container in (report.get("metrics"), report):
        if not isinstance(container, dict):
            continue
        if dotted in container:
            return container[dotted]
        value = nested_get(container, path)
        if value is not MISSING:
            return value
    return MISSING


def numeric(value: Any) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value)
        except ValueError:
            return None
    else:
        return None
    if not math.isfinite(number):
        return None
    return number


def normalize_chip_group(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    text = value.strip().lower().replace("-", "_").replace(" ", "_")
    if text in {"m1_m2", "m1m2"}:
        return "m1_m2"
    if text in {"m3_m5", "m3m5"}:
        return "m3_m5"
    if text.startswith("apple_"):
        text = text.removeprefix("apple_")
    if text.startswith("m1") or text.startswith("m2"):
        return "m1_m2"
    if text.startswith("m3") or text.startswith("m4") or text.startswith("m5"):
        return "m3_m5"
    return None


def report_chip_group(report: dict[str, Any], override: str | None) -> str | None:
    if override:
        return normalize_chip_group(override)
    for path in (
        ("chip_group",),
        ("chipGroup",),
        ("chip",),
        ("hardware", "chip"),
        ("system", "chip"),
        ("device", "chip"),
    ):
        value = nested_get(report, path)
        group = normalize_chip_group(value)
        if group:
            return group
    return None


def selected_thresholds(threshold_doc: dict[str, Any], chip_group: str | None) -> dict[str, Any]:
    base = threshold_doc.get("default") or threshold_doc.get("thresholds") or {}
    if not isinstance(base, dict):
        raise ValueError("threshold JSON must contain an object at 'default' or 'thresholds'")
    if not chip_group:
        return copy.deepcopy(base)
    chips = threshold_doc.get("chips", {})
    override = chips.get(chip_group, {}) if isinstance(chips, dict) else {}
    if not isinstance(override, dict):
        raise ValueError(f"threshold override for chip group {chip_group!r} must be an object")
    return deep_merge(base, override)


def report_name(path: Path, index: int, report: dict[str, Any]) -> str:
    for key in ("id", "name", "model", "run_id"):
        value = report.get(key)
        if value is not None:
            return f"{path.name}:{value}"
    return f"{path.name}#{index + 1}"


def evaluate_report(
    report_path: Path,
    report_index: int,
    report: dict[str, Any],
    threshold_doc: dict[str, Any],
    chip_override: str | None,
    strict_missing: bool,
) -> tuple[int, int, int]:
    chip_group = report_chip_group(report, chip_override)
    thresholds = selected_thresholds(threshold_doc, chip_group)
    label = report_name(report_path, report_index, report)
    chip_label = chip_group or "default"

    passed = failed = skipped = 0
    print(f"\nReport {label} (threshold profile={threshold_doc.get('profile', 'unknown')}, chip={chip_label})")
    for metric_path, rule in iter_thresholds(thresholds):
        metric = ".".join(metric_path)
        raw = metric_value(report, metric_path)
        if raw is MISSING:
            if strict_missing:
                failed += 1
                print(f"  FAIL {metric}: missing")
            else:
                skipped += 1
                print(f"  SKIP {metric}: missing")
            continue

        value = numeric(raw)
        if value is None:
            if strict_missing:
                failed += 1
                print(f"  FAIL {metric}: non-numeric value {raw!r}")
            else:
                skipped += 1
                print(f"  SKIP {metric}: non-numeric value {raw!r}")
            continue

        errors = []
        if "min" in rule and value < float(rule["min"]):
            errors.append(f"below min {rule['min']}")
        if "max" in rule and value > float(rule["max"]):
            errors.append(f"above max {rule['max']}")

        if errors:
            failed += 1
            print(f"  FAIL {metric}: {value:g} ({'; '.join(errors)})")
        else:
            passed += 1
            bounds = []
            if "min" in rule:
                bounds.append(f"min {rule['min']}")
            if "max" in rule:
                bounds.append(f"max {rule['max']}")
            print(f"  PASS {metric}: {value:g} ({', '.join(bounds)})")

    return passed, failed, skipped


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare KV quant JSON reports against threshold JSON.")
    parser.add_argument("reports", nargs="+", type=Path, help="JSON or JSONL report files to evaluate.")
    parser.add_argument("-t", "--thresholds", required=True, type=Path, help="Threshold JSON file.")
    parser.add_argument("--chip", choices=("m1_m2", "m3_m5"), help="Override chip group for all reports.")
    parser.add_argument(
        "--strict-missing",
        action="store_true",
        help="Treat missing or non-numeric thresholded metrics as failures instead of skips.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    threshold_doc = json.loads(args.thresholds.read_text(encoding="utf-8"))
    if not isinstance(threshold_doc, dict):
        raise ValueError("threshold file must contain a JSON object")

    total_passed = total_failed = total_skipped = 0
    for report_path in args.reports:
        reports = load_json_or_jsonl(report_path)
        for index, report in enumerate(reports):
            passed, failed, skipped = evaluate_report(
                report_path,
                index,
                report,
                threshold_doc,
                args.chip,
                args.strict_missing,
            )
            total_passed += passed
            total_failed += failed
            total_skipped += skipped

    print(f"\nSummary: {total_passed} passed, {total_failed} failed, {total_skipped} skipped")
    return 1 if total_failed else 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
