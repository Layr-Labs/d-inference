from __future__ import annotations

import fnmatch
import json
from dataclasses import dataclass
from typing import Any

from .client import Observation, TargetRun
from .config import DifferenceRule


MISSING = object()


@dataclass(frozen=True)
class Difference:
    scenario: str
    path: str
    go: Any
    rust: Any
    allowed_by: str | None = None


@dataclass(frozen=True)
class Comparison:
    passed: bool
    differences: tuple[Difference, ...]
    allowed_differences: tuple[Difference, ...]
    used_rules: tuple[str, ...]
    unused_rules: tuple[str, ...]


def compare_runs(
    go: TargetRun,
    rust: TargetRun,
    rules: tuple[DifferenceRule, ...],
) -> Comparison:
    go_by_index = {item.index: item for item in go.observations}
    rust_by_index = {item.index: item for item in rust.observations}
    differences: list[Difference] = []
    allowed: list[Difference] = []
    used_rules: set[str] = set()
    for index in sorted(set(go_by_index) | set(rust_by_index)):
        go_item = go_by_index.get(index)
        rust_item = rust_by_index.get(index)
        scenario = (go_item or rust_item).scenario
        if go_item is None or rust_item is None:
            differences.append(
                Difference(
                    scenario=scenario,
                    path="observation",
                    go="missing" if go_item is None else "present",
                    rust="missing" if rust_item is None else "present",
                )
            )
            continue
        comparable_go = _comparable(go_item)
        comparable_rust = _comparable(rust_item)
        flattened_go = _flatten(comparable_go)
        flattened_rust = _flatten(comparable_rust)
        for path in sorted(set(flattened_go) | set(flattened_rust)):
            go_value = flattened_go.get(path, MISSING)
            rust_value = flattened_rust.get(path, MISSING)
            if go_value == rust_value:
                continue
            rule = _matching_rule(rules, scenario, path, go_value, rust_value)
            difference = Difference(
                scenario=scenario,
                path=path,
                go=_printable(go_value),
                rust=_printable(rust_value),
                allowed_by=rule.id if rule else None,
            )
            if rule:
                allowed.append(difference)
                used_rules.add(rule.id)
            else:
                differences.append(difference)
    return Comparison(
        passed=not differences,
        differences=tuple(differences),
        allowed_differences=tuple(allowed),
        used_rules=tuple(sorted(used_rules)),
        unused_rules=tuple(sorted(rule.id for rule in rules if rule.id not in used_rules)),
    )


def compare_database_snapshots(
    go: dict[str, Any],
    rust: dict[str, Any],
    rules: tuple[DifferenceRule, ...],
) -> Comparison:
    comparable_go = {"database": go.get("tables", {})}
    comparable_rust = {"database": rust.get("tables", {})}
    differences: list[Difference] = []
    allowed: list[Difference] = []
    used_rules: set[str] = set()
    flattened_go = _flatten(comparable_go)
    flattened_rust = _flatten(comparable_rust)
    for path in sorted(set(flattened_go) | set(flattened_rust)):
        go_value = flattened_go.get(path, MISSING)
        rust_value = flattened_rust.get(path, MISSING)
        if go_value == rust_value:
            continue
        rule = _matching_rule(rules, "database", path, go_value, rust_value)
        difference = Difference(
            scenario="database",
            path=path,
            go=_printable(go_value),
            rust=_printable(rust_value),
            allowed_by=rule.id if rule else None,
        )
        if rule:
            allowed.append(difference)
            used_rules.add(rule.id)
        else:
            differences.append(difference)
    return Comparison(
        passed=not differences,
        differences=tuple(differences),
        allowed_differences=tuple(allowed),
        used_rules=tuple(sorted(used_rules)),
        unused_rules=tuple(sorted(rule.id for rule in rules if rule.id not in used_rules)),
    )


def _comparable(observation: Observation) -> dict[str, Any]:
    content_type = observation.headers.get("content-type", "")
    return {
        "status": observation.status,
        "error": observation.error,
        "headers": observation.headers,
        **_decode_body(observation.body, content_type),
    }


def _decode_body(body: bytes, content_type: str) -> dict[str, Any]:
    text = body.decode("utf-8", errors="replace")
    if "text/event-stream" in content_type or text.lstrip().startswith(("data:", ":")):
        return {"sse": _parse_sse(text)}
    try:
        return {"body": json.loads(text)}
    except json.JSONDecodeError:
        return {"body_text": text}


def _parse_sse(text: str) -> list[Any]:
    events: list[Any] = []
    for block in text.replace("\r\n", "\n").split("\n\n"):
        data_lines: list[str] = []
        metadata: dict[str, str] = {}
        for line in block.splitlines():
            if not line or line.startswith(":"):
                continue
            field, separator, value = line.partition(":")
            if separator and value.startswith(" "):
                value = value[1:]
            if field == "data":
                data_lines.append(value)
            elif field in {"event", "id", "retry"}:
                metadata[field] = value
        if not data_lines:
            continue
        payload = "\n".join(data_lines)
        if payload == "[DONE]":
            decoded: Any = "[DONE]"
        else:
            try:
                decoded = json.loads(payload)
            except json.JSONDecodeError:
                decoded = payload
        if metadata:
            events.append({"data": decoded, **metadata})
            continue
        events.append(decoded)
    return events


def _flatten(value: Any, prefix: str = "") -> dict[str, Any]:
    if isinstance(value, dict):
        if not value:
            return {prefix: {}}
        flattened: dict[str, Any] = {}
        for key in sorted(value):
            child = f"{prefix}/{key}" if prefix else str(key)
            flattened.update(_flatten(value[key], child))
        return flattened
    if isinstance(value, list):
        if not value:
            return {prefix: []}
        flattened = {}
        for index, item in enumerate(value):
            child = f"{prefix}/{index}" if prefix else str(index)
            flattened.update(_flatten(item, child))
        return flattened
    return {prefix: value}


def _matching_rule(
    rules: tuple[DifferenceRule, ...],
    scenario: str,
    path: str,
    go: Any,
    rust: Any,
) -> DifferenceRule | None:
    for rule in rules:
        if not fnmatch.fnmatchcase(scenario, rule.scenario) or not fnmatch.fnmatchcase(path, rule.path):
            continue
        if rule.action == "ignore_value" and go is not MISSING and rust is not MISSING:
            return rule
        if rule.action == "presence":
            if (go is MISSING) != (rust is MISSING):
                return rule
            continue
        if rule.action == "same_type" and go is not MISSING and rust is not MISSING:
            if _json_type(go) == _json_type(rust):
                return rule
        if (
            rule.action == "numeric_delta"
            and _is_number(go)
            and _is_number(rust)
            and go - rust == rule.go_minus_rust
        ):
            return rule
    return None


def _json_type(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _printable(value: Any) -> Any:
    return "<missing>" if value is MISSING else value
