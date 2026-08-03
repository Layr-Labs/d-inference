"""Baseline loading and the fail-closed pins that gate a comparison.

A percentage delta against a reference report is only an *engine* delta if
everything else is held constant. These checks refuse to compare when the model
snapshot, the host hardware, the workload shape, or the performance-relevant
environment differs, instead of silently attributing a weight/config/hardware/
kill-switch difference to the code under test.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from .config import SCHEMA_VERSION
from .environment import baseline_environment


NO_COMPARE_HINT = "omit --baseline to run without a comparison"

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
        "batchSizes": list(args.batch_sizes),
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
            + "; " + NO_COMPARE_HINT
        )


def describe_env_value(value: str | None) -> str:
    """`unset` is a bareword so it cannot be confused with the string 'unset'."""
    return "unset" if value is None else repr(value)


def validate_environment_pin(baseline: dict, environment: dict[str, str]) -> None:
    """Refuse to compare when engine kill switches or MLX flags differ.

    Values are compared verbatim. The harness does not normalise truthiness
    ("0" vs "false" vs unset): each switch decides that for itself, and a
    guess here would silently re-open the hole this pin closes.

    The asymmetry that matters is a baseline with no recorded environment --
    an older report predates this pin. Such a baseline is read as an
    implicit *empty* environment, i.e. "recorded with engine defaults":

      * absent in baseline + empty run  -> match, the comparison proceeds.
        Both sides are the default configuration, which is exactly what the
        reference report was recorded under.
      * absent in baseline + non-empty run -> REFUSE. This is the dangerous
        case the pin exists for: a switch flipped on one side only, whose
        effect would otherwise be reported as a code regression (or hide one).

    That is deliberately not fail-open: the only permissive path requires the
    run itself to carry no overrides. The residual risk is an old baseline
    recorded *with* an override by a runner too old to write the block; the
    older smoke reports were not, and every report written from here on
    records the block unconditionally (empty dict when nothing is set), so the
    ambiguity is bounded to reports predating this pin.
    """
    try:
        recorded = baseline_environment(baseline)
    except RuntimeError as error:
        raise RuntimeError(f"{error}; {NO_COMPARE_HINT}") from error
    baseline_values = {} if recorded is None else recorded
    # Union of keys, taking the baseline's record verbatim: the run side is
    # already allowlist-filtered at capture, and filtering the baseline again
    # here would let a hand-edited pin disappear instead of refusing.
    mismatches = [
        f"{name}={describe_env_value(environment.get(name))} "
        f"(baseline {describe_env_value(baseline_values.get(name))})"
        for name in sorted(set(environment) | set(baseline_values))
        if environment.get(name) != baseline_values.get(name)
    ]
    if not mismatches:
        return
    subject = (
        "the baseline, which records none (read as engine defaults)"
        if recorded is None
        else "the baseline environment"
    )
    raise RuntimeError(
        f"performance environment does not match {subject}: "
        + ", ".join(mismatches)
        + "; "
        + NO_COMPARE_HINT
    )


def validate_schema_version_pin(baseline: dict) -> None:
    """Refuse a baseline written against a different wrapper schema.

    Schema 3 removed `configuration.maxBatch` and added the `kvBackend`
    block. A schema-2 baseline therefore records a batch ladder this runner
    cannot see and no backend at all, so every pin below it reads absent
    fields as "not recorded" and the comparison silently comes out as a
    same-shape delta between two different experiments. Fail here instead.
    """
    recorded = baseline.get("schemaVersion")
    if recorded == SCHEMA_VERSION:
        return
    raise RuntimeError(
        f"baseline schemaVersion is {recorded!r}, this runner writes "
        f"{SCHEMA_VERSION}; the two reports do not describe the same fields "
        f"(schema 3 replaced configuration.maxBatch with configuration."
        f"batchSizes and added the kvBackend block); "
        + "re-record the baseline with this runner, or " + NO_COMPARE_HINT
    )


def validate_baseline_pins(
    args: argparse.Namespace,
    baseline: dict,
    model_snapshot: str,
    hardware: dict,
    environment: dict[str, str],
) -> None:
    """Every pin that must hold before a delta can be read as an engine delta."""
    # First: every pin below reads named fields, and a schema mismatch makes
    # "absent" indistinguishable from "unrecorded".
    validate_schema_version_pin(baseline)
    validate_model_pin(baseline, args.model, model_snapshot)
    validate_hardware_pin(baseline, hardware)
    validate_configuration_pin(args, baseline)
    validate_environment_pin(baseline, environment)
