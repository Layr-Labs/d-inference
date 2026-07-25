"""Baseline loading and the fail-closed pins that gate a comparison.

A percentage delta against the committed baseline is only an *engine* delta if
everything else is held constant. These checks refuse to compare when the model
snapshot, the host hardware, or the workload shape differs, instead of silently
attributing a weight/config/hardware difference to the code under test.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


NO_COMPARE_HINT = "pass --no-compare to run without a baseline comparison"

HARDWARE_FIELDS = ("chipName", "gpuCores", "memoryGb", "memoryBandwidthGbs")


def load_baseline(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        baseline = json.load(handle)
    if not isinstance(baseline, dict):
        raise RuntimeError(f"baseline {path} is not a JSON object")
    return baseline


def resolve_model_snapshot(raw_outputs: dict[str, dict]) -> str:
    """The HuggingFace snapshot directory name shared by every raw payload.

    `ModelScanner.resolveLocalPath` returns `.../snapshots/<commit>`, so the
    final path component identifies the exact weights that were measured. All
    three benchmarks must have resolved the same one.
    """
    snapshots: dict[str, str] = {}
    for name, payload in raw_outputs.items():
        model_path = payload.get("modelPath")
        if not isinstance(model_path, str) or not model_path.strip():
            raise RuntimeError(f"{name} did not report a model path")
        snapshots[name] = Path(model_path).name
    distinct = sorted(set(snapshots.values()))
    if len(distinct) != 1:
        raise RuntimeError(
            "benchmarks resolved different model snapshots: "
            + ", ".join(f"{name}={value}" for name, value in sorted(snapshots.items()))
        )
    snapshot = distinct[0]
    if not snapshot:
        raise RuntimeError("resolved an empty model snapshot directory")
    return snapshot


def validate_model_pin(baseline: dict, model_id: str, model_snapshot: str) -> None:
    baseline_model = baseline.get("modelID")
    if baseline_model != model_id:
        raise RuntimeError(
            f"baseline model {baseline_model} does not match {model_id}; "
            + NO_COMPARE_HINT
        )
    baseline_snapshot = baseline.get("modelSnapshot")
    if not isinstance(baseline_snapshot, str) or not baseline_snapshot.strip():
        raise RuntimeError(
            "baseline does not pin modelSnapshot, so weight differences would be "
            "reported as engine deltas; " + NO_COMPARE_HINT
        )
    if baseline_snapshot != model_snapshot:
        raise RuntimeError(
            f"model snapshot {model_snapshot} does not match the baseline "
            f"snapshot {baseline_snapshot}; " + NO_COMPARE_HINT
        )


def validate_hardware_pin(baseline: dict, hardware: dict) -> None:
    baseline_hardware = baseline.get("hardware")
    if not isinstance(baseline_hardware, dict):
        raise RuntimeError(
            "baseline does not pin hardware, so host differences would be reported "
            "as engine deltas; " + NO_COMPARE_HINT
        )
    missing = [field for field in HARDWARE_FIELDS if field not in baseline_hardware]
    if missing:
        raise RuntimeError(
            "baseline hardware is missing " + ", ".join(missing) + "; " + NO_COMPARE_HINT
        )
    mismatches = [
        f"{field}={hardware.get(field)!r} (baseline {baseline_hardware[field]!r})"
        for field in HARDWARE_FIELDS
        if hardware.get(field) != baseline_hardware[field]
    ]
    if mismatches:
        raise RuntimeError(
            "hardware does not match the baseline host: "
            + ", ".join(mismatches)
            + "; "
            + NO_COMPARE_HINT
        )


def validate_configuration_pin(args: argparse.Namespace, baseline: dict) -> None:
    baseline_configuration = baseline.get("configuration")
    if not isinstance(baseline_configuration, dict):
        raise RuntimeError("baseline does not record a configuration; " + NO_COMPARE_HINT)
    expected = {
        "decodePromptTokens": args.decode_prompt_tokens,
        "decodeTokens": args.decode_tokens,
        "arrivalPromptTokens": args.arrival_prompt_tokens,
        "arrivalDecodeTokens": args.arrival_decode_tokens,
        "maxBatch": args.max_batch,
        "prefillLengths": list(args.prefill_lengths),
    }
    mismatches = [
        f"{key}={value} (baseline {baseline_configuration.get(key)})"
        for key, value in expected.items()
        if baseline_configuration.get(key) != value
    ]
    if mismatches:
        raise RuntimeError(
            "benchmark shape is not comparable to the baseline: "
            + ", ".join(mismatches)
            + "; pass --no-compare for a different workload"
        )


def validate_baseline_pins(
    args: argparse.Namespace,
    baseline: dict,
    model_snapshot: str,
    hardware: dict,
) -> None:
    """Every pin that must hold before a delta can be read as an engine delta."""
    validate_model_pin(baseline, args.model, model_snapshot)
    validate_hardware_pin(baseline, hardware)
    validate_configuration_pin(args, baseline)
