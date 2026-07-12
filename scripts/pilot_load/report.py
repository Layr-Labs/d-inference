from __future__ import annotations

import json
import os
import tempfile
from dataclasses import asdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .baseline import load_baseline
from .compare import Comparison
from .config import Profile
from .metrics import GateFailure


def build_report(
    profile: Profile,
    summaries: dict[str, dict],
    comparison: Comparison,
    database_comparison: Comparison | None,
    database_snapshots: dict[str, dict] | None,
    resources: dict | None,
    skipped_scenarios: list[str],
    failures: list[GateFailure],
    metadata: dict[str, Any],
) -> dict[str, Any]:
    all_differences = list(comparison.differences)
    all_allowed = list(comparison.allowed_differences)
    used_rules = set(comparison.used_rules)
    all_rule_ids = used_rules | set(comparison.unused_rules)
    if database_comparison:
        all_differences.extend(database_comparison.differences)
        all_allowed.extend(database_comparison.allowed_differences)
        used_rules.update(database_comparison.used_rules)
        all_rule_ids.update(database_comparison.used_rules)
        all_rule_ids.update(database_comparison.unused_rules)
    passed = not failures and not all_differences
    review_required = (
        passed
        and profile.require_regression_baseline
        and metadata.get("regression_baseline_mode") == "capture"
    )
    verdict = (
        "baseline_review_required"
        if review_required
        else ("pass" if passed else "fail")
    )
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "profile": {
            "name": profile.name,
            "description": profile.description,
            "seed": profile.seed,
            "duration_seconds": profile.duration_seconds,
            "soak": profile.soak,
            "request_count": profile.request_count,
            "request_multiplier": profile.request_multiplier,
            "chunk_multiplier": profile.chunk_multiplier,
            "websocket_sessions": profile.websocket_sessions,
            "concurrency_ramp": list(profile.concurrency_ramp),
            "slow_consumer_fraction": profile.slow_consumer_fraction,
            "stage_budgets_ms": profile.stage_budgets_ms,
            "resource_bounds": profile.resource_bounds,
            "regression_thresholds": profile.regression_thresholds,
            "require_billing_snapshot": profile.require_billing_snapshot,
            "require_prediction_samples": profile.require_prediction_samples,
            "require_resource_counters": profile.require_resource_counters,
            "require_peer_counters": profile.require_peer_counters,
            "require_regression_baseline": profile.require_regression_baseline,
        },
        "metadata": metadata,
        "verdict": verdict,
        "authorization_eligible": verdict == "pass",
        "targets": summaries,
        "comparison": {
            "passed": not all_differences,
            "differences": [asdict(item) for item in all_differences],
            "allowed_differences": [asdict(item) for item in all_allowed],
            "used_allowed_difference_rules": sorted(used_rules),
            "unused_allowed_difference_rules": sorted(all_rule_ids - used_rules),
        },
        "skipped_scenarios": sorted(skipped_scenarios),
        "database": database_snapshots,
        "resources": resources,
        "gate_failures": [asdict(failure) for failure in failures],
    }


def write_reports(report: dict[str, Any], json_path: Path, markdown_path: Path) -> None:
    _atomic_write(json_path, json.dumps(report, indent=2, sort_keys=True) + "\n")
    _atomic_write(markdown_path, markdown(report))


def markdown(report: dict[str, Any]) -> str:
    profile = report["profile"]
    lines = [
        "# Coordinator differential pilot report",
        "",
        f"- Verdict: **{report['verdict'].upper()}**",
        f"- Profile: `{profile['name']}`",
        f"- Deterministic seed: `{profile['seed']}`",
        f"- Soak: `{profile['soak']}` (configured duration `{profile['duration_seconds']}s`)",
        f"- Requests per target: `{profile['request_count']}` load + contract trace",
        f"- WS target: `{profile['websocket_sessions']}` sessions",
        f"- Load multipliers: `{profile['request_multiplier']}x` requests / `{profile['chunk_multiplier']}x` chunks",
        "",
        "## Throughput and latency",
        "",
        "| Target | Requests | Throughput req/s | Total p50 ms | Total p95 ms | Total p99 ms | Total max ms | Prediction MAE ms |",
        "|---|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for target, summary in report["targets"].items():
        total = summary["stages_ms"].get("total", {})
        prediction = summary["prediction_error_ms"]
        lines.append(
            "| {target} | {requests} | {throughput:.2f} | {p50} | {p95} | {p99} | {maximum} | {mae} |".format(
                target=target,
                requests=summary["requests"],
                throughput=summary["throughput_rps"],
                p50=_number(total.get("p50")),
                p95=_number(total.get("p95")),
                p99=_number(total.get("p99")),
                maximum=_number(total.get("max")),
                mae=_number(prediction.get("mean_absolute")),
            )
        )
    lines.extend(
        [
            "",
            "## Stage budgets",
            "",
            "| Target | Stage | Samples | p50 ms | p95 ms | p99 ms | max ms |",
            "|---|---|---:|---:|---:|---:|---:|",
        ]
    )
    for target, summary in report["targets"].items():
        for stage, values in summary["stages_ms"].items():
            lines.append(
                f"| {target} | {stage} | {values['samples']} | {_number(values['p50'])} | "
                f"{_number(values['p95'])} | {_number(values['p99'])} | {_number(values['max'])} |"
            )
    comparison = report["comparison"]
    lines.extend(
        [
            "",
            "## Differential result",
            "",
            f"- Unapproved differences: `{len(comparison['differences'])}`",
            f"- Manifest-approved differences: `{len(comparison['allowed_differences'])}`",
            f"- Skipped required scenarios: `{len(report['skipped_scenarios'])}`",
        ]
    )
    if comparison["differences"]:
        lines.extend(["", "| Scenario | Path | Go | Rust |", "|---|---|---|---|"])
        for difference in comparison["differences"][:100]:
            lines.append(
                f"| {difference['scenario']} | `{difference['path']}` | "
                f"`{_short(difference['go'])}` | `{_short(difference['rust'])}` |"
            )
    lines.extend(["", "## Gate failures", ""])
    if report["gate_failures"]:
        lines.extend(["| Gate | Actual | Limit |", "|---|---:|---:|"])
        for failure in report["gate_failures"]:
            lines.append(
                f"| `{failure['gate']}` | `{_short(failure['actual'])}` | `{_short(failure['limit'])}` |"
            )
    else:
        lines.append("All configured differential, budget, baseline, resource, and database gates passed.")
    lines.append("")
    return "\n".join(lines)


def _atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent, text=True)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _number(value: Any) -> str:
    return "n/a" if value is None else f"{value:.2f}"


def _short(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True) if not isinstance(value, str) else value
    encoded = encoded.replace("|", "\\|").replace("`", "'").replace("\n", " ")
    return encoded if len(encoded) <= 120 else encoded[:117] + "..."
