"""The KV backend a run ACTUALLY measured, and the pin that gates a diff.

A decode curve is only comparable to another decode curve if both were
produced by the same KV backend. Nothing else in this harness can establish
that: `--kv-backend auto` is a *selection*, and since v0.8.0 it resolves paged
but still degrades to contiguous on the fleet kill switch, on kernel
preflight, or on pool capacity. A degraded run measures the rollback backend
while every other check in this wrapper stays green, and a percentage delta
against a baseline recorded on the other backend is a backend change wearing a
performance change's clothes.

So the resolved backend is extracted per decode cell, recorded in the report,
and pinned before any delta is computed.

Vocabulary is the resolved *kind* -- "paged" or "contiguous" -- matching
`EngineV2KVBackendKind.rawValue` and the `kv_backend` field the coordinator
records per slot. The engine's verbatim descriptor (which may carry a
"(fallback: ...)" tail) is kept alongside it for diagnosis.
"""

from __future__ import annotations

import argparse

from .baseline import NO_COMPARE_HINT


KNOWN_KINDS = ("contiguous", "paged")


def backend_kind(descriptor: str, path: str) -> str:
    """The resolved kind from an engine descriptor.

    `EngineV2Factory` reports either `"<kind>"` or
    `"<kind> (fallback: <reason>)"`, so the kind is the leading word. An
    unrecognised kind is refused rather than passed through: a gate that
    compares two strings it does not understand is not a gate.
    """
    if not isinstance(descriptor, str) or not descriptor.strip():
        raise RuntimeError(f"expected a resolved KV backend at {path}, got {descriptor!r}")
    kind = descriptor.split(" ", 1)[0]
    if kind not in KNOWN_KINDS:
        raise RuntimeError(
            f"unrecognised KV backend kind {kind!r} at {path}; "
            f"expected one of {', '.join(KNOWN_KINDS)}"
        )
    return kind


def resolve_kv_backend(args: argparse.Namespace, sweep: dict) -> dict:
    """Selection versus resolved backend, per decode cell.

    Raises when the sweep predates the structured `kvBackend` block or when a
    cell reports no backend at all -- an unattributable curve must not be
    silently recorded as if it were attributable.

    Returns the report block. `postureViolations` is non-empty when the run
    did not measure a single, named backend end to end; the caller writes the
    artifact anyway (the operator needs it precisely then) and fails the
    process off the list.
    """
    block = sweep.get("kvBackend")
    if not isinstance(block, dict):
        raise RuntimeError(
            "throughput sweep did not report a kvBackend block; the darkbloom "
            "binary predates schema 3 and cannot say which backend it measured"
        )
    selection = block.get("selection")
    if not isinstance(selection, str) or not selection.strip():
        raise RuntimeError("throughput sweep reported no kvBackend.selection")
    if selection != args.kv_backend:
        raise RuntimeError(
            f"throughput sweep ran --kv-backend {selection!r}, but this "
            f"wrapper requested {args.kv_backend!r}"
        )

    descriptors: list[str] = []
    kinds_by_batch: dict[str, list[str]] = {}
    for index, sample in enumerate(sweep.get("decode", [])):
        path = f"decode[{index}].resolvedKVBackend"
        descriptor = sample.get("resolvedKVBackend")
        if descriptor is None:
            raise RuntimeError(
                f"{path} is absent: batch size {sample.get('batchSize')!r} "
                "measured samples without recording a backend"
            )
        kind = backend_kind(descriptor, path)
        if descriptor not in descriptors:
            descriptors.append(descriptor)
        batch = str(sample.get("batchSize"))
        seen = kinds_by_batch.setdefault(batch, [])
        if kind not in seen:
            seen.append(kind)

    resolved = sorted({kind for kinds in kinds_by_batch.values() for kind in kinds})
    violations: list[str] = []
    if not resolved:
        violations.append("no decode cell resolved a KV backend")
    if len(resolved) > 1:
        # The case the per-cell record exists for: one engine per batch size,
        # so `auto` can hold paged at B=1 and degrade at B=8. Averaging that
        # curve describes neither backend.
        mixed = ", ".join(
            f"B={batch}: {'+'.join(kinds)}"
            for batch, kinds in sorted(kinds_by_batch.items(), key=lambda kv: int(kv[0]))
            if kinds
        )
        violations.append(
            f"mixed KV backend population across the decode curve ({mixed})"
        )
    # `auto` promises nothing, so there is nothing to hold it to. An explicit
    # selection is a claim, and OPEN-9 made it a refusal rather than a
    # degrade -- a resolved kind that disagrees with it means the refusal
    # leaked.
    if selection in KNOWN_KINDS:
        wrong = [kind for kind in resolved if kind != selection]
        if wrong:
            violations.append(
                f"--kv-backend {selection} resolved {', '.join(wrong)}"
            )

    return {
        "selection": selection,
        "resolved": resolved,
        "resolvedDescriptors": descriptors,
        "byBatchSize": {
            batch: "+".join(kinds) for batch, kinds in kinds_by_batch.items()
        },
        "postureViolations": violations,
    }


def validate_kv_backend_pin(baseline: dict, kv_backend: dict) -> None:
    """Refuse to compare two runs that measured different KV backends.

    This is the pin the paged rollout turns on. Every other number in the
    report is a rate, and a rate compared across backend populations is not a
    delta -- it is the difference between two engines relabelled as the
    difference between two commits.

    A baseline with no recorded block is refused outright rather than read
    permissively: unlike the environment pin, there is no "defaults" reading
    that makes an unrecorded backend safe, because the backend a report
    measured is not recoverable from anything else it wrote.
    """
    recorded = baseline.get("kvBackend")
    if not isinstance(recorded, dict):
        raise RuntimeError(
            "baseline does not record a resolved KV backend, so a paged/"
            "contiguous difference would be reported as an engine delta; "
            + NO_COMPARE_HINT
        )
    baseline_resolved = recorded.get("resolved")
    if not isinstance(baseline_resolved, list) or not baseline_resolved:
        raise RuntimeError(
            "baseline records no resolved KV backend for its decode curve; "
            + NO_COMPARE_HINT
        )

    mismatches = []
    if recorded.get("selection") != kv_backend["selection"]:
        mismatches.append(
            f"selection={kv_backend['selection']!r} "
            f"(baseline {recorded.get('selection')!r})"
        )
    if sorted(baseline_resolved) != kv_backend["resolved"]:
        mismatches.append(
            f"resolved={kv_backend['resolved']} (baseline {sorted(baseline_resolved)})"
        )
    # Per cell, not just in aggregate: two runs can agree on the set of
    # backends present and still disagree about which batch size ran on
    # which, and the per-batch deltas are exactly what the report tabulates.
    baseline_by_batch = recorded.get("byBatchSize")
    if isinstance(baseline_by_batch, dict):
        for batch in sorted(
            set(baseline_by_batch) | set(kv_backend["byBatchSize"]),
            key=lambda value: (len(value), value),
        ):
            current = kv_backend["byBatchSize"].get(batch)
            reference = baseline_by_batch.get(batch)
            if current != reference:
                mismatches.append(f"B={batch}: {current!r} (baseline {reference!r})")

    if mismatches:
        raise RuntimeError(
            "KV backend does not match the baseline, so the delta would "
            "compare across backend populations: "
            + ", ".join(mismatches)
            + "; "
            + NO_COMPARE_HINT
        )
