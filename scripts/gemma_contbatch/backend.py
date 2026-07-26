"""The KV backend a run ACTUALLY measured, and the pin that gates a diff.

A decode curve is only comparable to another decode curve if both were
produced by the same KV backend. Nothing else in this harness can establish
that: `--kv-backend auto` is a *selection*. It resolves contiguous (the
v0.8.0 flip to paged was reverted -- paged adoption is not transparent), and
an explicit `paged` can still be vetoed by the fleet kill switch. A run that
did not build the backend it names measures the fallback while every other
check in this wrapper stays green, and a percentage delta against a baseline
recorded on the other backend is a backend change wearing a performance
change's clothes.

So the resolved backend is extracted per decode cell, recorded in the report,
and pinned before any delta is computed.

Vocabulary is the resolved *kind* -- "paged" or "contiguous" -- matching
`EngineV2KVBackendKind.rawValue` and the `kv_backend` field the coordinator
records per slot. The engine's verbatim descriptor carries a
"(fallback: <reason>)" tail on a degrade, and that reason is extracted into
`degrades`: with paged opt-in, a deliberately paged slot quietly serving
contiguous is the failure that matters, and only the reason separates a
machine that cannot serve paged from one that simply was not PACKAGED for
it -- the kernel preflight resolves its SwiftPM resource bundle relative to
the executable, so a bare `cp` of the binary without the `.bundle` beside it
disables paged on a box that is perfectly capable of running it.
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


def degrade_reason(descriptor: str) -> str | None:
    """The `(fallback: ...)` tail of an engine descriptor, if any."""
    marker = " (fallback: "
    if marker not in descriptor or not descriptor.endswith(")"):
        return None
    return descriptor.split(marker, 1)[1][:-1]


def validate_decode_coverage(sweep: dict) -> None:
    """Every requested decode cell must have produced a measurement.

    Since schema 4 the sweep says which cells it set out to measure and which
    ones never built an engine. Without this the operator sees the generic
    "expected positive metric at decode[6].aggregateTokensPerSecond" instead
    of the batch size that went missing and the construction error that took
    it out -- and with paged refusing per cell (each builds its own engine,
    sized by its own concurrency), a lost B=8 is the single most likely and
    most expensive cell to lose.
    """
    coverage = sweep.get("decodeCoverage")
    if not isinstance(coverage, dict):
        raise RuntimeError(
            "throughput sweep did not report a decodeCoverage block; the "
            "darkbloom binary predates schema 4 and cannot say whether every "
            "requested decode cell was measured"
        )
    unmeasured = coverage.get("unmeasured") or []
    if unmeasured:
        raise RuntimeError(
            f"{len(unmeasured)} of {len(coverage.get('requestedBatchSizes') or [])} "
            "requested decode cells built no engine: "
            + "; ".join(
                f"B={cell.get('batchSize')}: {cell.get('reason')}"
                for cell in unmeasured
            )
        )


def phase_selection(label: str, payload: dict, requested: str) -> str:
    """The `--kv-backend` selection a phase reports it was launched with.

    Read back from the payload rather than assumed from the wrapper's own
    argv: "the wrapper passed the flag" and "the binary ran that selection"
    are different facts, and only the second one is evidence. A build that
    accepts the flag and ignores it -- which every phase but the sweep did
    before this pin -- is caught here rather than reported as a paged run.
    """
    block = payload.get("kvBackend")
    if not isinstance(block, dict):
        raise RuntimeError(
            f"{label} did not report a kvBackend block; the darkbloom binary "
            "predates the per-phase backend pin and cannot say which backend "
            "it measured"
        )
    selection = block.get("selection")
    if not isinstance(selection, str) or not selection.strip():
        raise RuntimeError(f"{label} reported no kvBackend.selection")
    if selection != requested:
        raise RuntimeError(
            f"{label} ran --kv-backend {selection!r}, but this wrapper "
            f"requested {requested!r}"
        )
    return selection


def phase_descriptors(label: str, payload: dict) -> list[str]:
    """The resolved-backend descriptors a non-sweep phase built engines with.

    The sweep records one per decode cell; these phases de-duplicate in the
    binary, so the block's `resolved` list is the whole population.
    """
    resolved = payload["kvBackend"].get("resolved")
    if not isinstance(resolved, list):
        raise RuntimeError(f"{label} reported no kvBackend.resolved list")
    return [str(descriptor) for descriptor in resolved]


def resolve_kv_backend(
    args: argparse.Namespace, sweep: dict, scheduler: dict, arrival: dict
) -> dict:
    """Selection versus resolved backend, per decode cell AND per phase.

    Raises when a payload predates the structured blocks, when a requested
    decode cell went unmeasured, when a cell reports no backend at all, or
    when a phase ran a selection this wrapper did not ask for -- an
    unattributable run must not be silently recorded as if it were
    attributable.

    Every phase builds its own production engines, so every phase can resolve
    its own backend: a sweep measuring paged beside a scheduler-prefill phase
    measuring contiguous is one report describing two arms, and on the models
    production serves those two arms are not even numerically equivalent.
    That population is recorded in `byPhase` and, when it is not singular,
    called out as a posture violation rather than left to be inferred.

    Returns the report block. `postureViolations` is non-empty when the run
    did not measure a single, named backend end to end; the caller writes the
    artifact anyway (the operator needs it precisely then) and fails the
    process off the list.
    """
    validate_decode_coverage(sweep)
    selection = phase_selection("throughput sweep", sweep, args.kv_backend)
    phase_selection("scheduler prefill", scheduler, args.kv_backend)
    phase_selection("arrival invariance", arrival, args.kv_backend)

    descriptors: list[str] = []
    degrades: list[str] = []
    kinds_by_batch: dict[str, list[str]] = {}
    kinds_by_phase: dict[str, list[str]] = {}

    def record(descriptor: str, path: str, phase: str) -> str:
        kind = backend_kind(descriptor, path)
        if descriptor not in descriptors:
            descriptors.append(descriptor)
        reason = degrade_reason(descriptor)
        if reason is not None and reason not in degrades:
            degrades.append(reason)
        seen = kinds_by_phase.setdefault(phase, [])
        if kind not in seen:
            seen.append(kind)
        return kind

    for index, sample in enumerate(sweep.get("decode", [])):
        path = f"decode[{index}].resolvedKVBackend"
        descriptor = sample.get("resolvedKVBackend")
        if descriptor is None:
            raise RuntimeError(
                f"{path} is absent: batch size {sample.get('batchSize')!r} "
                "measured samples without recording a backend"
            )
        kind = record(descriptor, path, "throughputSweep")
        batch = str(sample.get("batchSize"))
        seen = kinds_by_batch.setdefault(batch, [])
        if kind not in seen:
            seen.append(kind)

    for phase, label, payload in (
        ("schedulerPrefill", "scheduler prefill", scheduler),
        ("arrivalInvariance", "arrival invariance", arrival),
    ):
        for index, descriptor in enumerate(phase_descriptors(label, payload)):
            record(descriptor, f"{phase}.kvBackend.resolved[{index}]", phase)

    decode_kinds = sorted({kind for kinds in kinds_by_batch.values() for kind in kinds})
    resolved = sorted({kind for kinds in kinds_by_phase.values() for kind in kinds})
    violations: list[str] = []
    if not decode_kinds:
        violations.append("no decode cell resolved a KV backend")
    for phase in ("schedulerPrefill", "arrivalInvariance"):
        if not kinds_by_phase.get(phase):
            violations.append(f"{phase} resolved no KV backend")
    if len(decode_kinds) > 1:
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
    if len({"+".join(kinds) for kinds in kinds_by_phase.values() if kinds}) > 1:
        # The defect this pin closes: the sweep names a backend and the two
        # phases beside it quietly measured whatever `.auto` resolved, so the
        # report's headline backend described one third of the run.
        mixed = ", ".join(
            f"{phase}: {'+'.join(kinds) or 'none'}"
            for phase, kinds in kinds_by_phase.items()
        )
        violations.append(f"mixed KV backend population across phases ({mixed})")
    # `auto` promises nothing, so there is nothing to hold it to. An explicit
    # selection is a claim -- a resolved kind that disagrees with it, or a
    # degrade of any kind under it, means the refusal path leaked.
    if selection in KNOWN_KINDS:
        wrong = [kind for kind in resolved if kind != selection]
        if wrong:
            violations.append(
                f"--kv-backend {selection} resolved {', '.join(wrong)}"
                + (f" ({'; '.join(degrades)})" if degrades else "")
            )
        elif degrades:
            violations.append(
                f"--kv-backend {selection} was degraded: {'; '.join(degrades)}"
            )

    return {
        "selection": selection,
        # Every kind ANY phase built, not just the decode curve's: a run whose
        # sweep is paged and whose prefill is contiguous has measured both,
        # and a baseline pinned on the decode set alone would compare the two
        # populations without noticing.
        "resolved": resolved,
        "resolvedDescriptors": descriptors,
        # The fallback reasons behind any degrade, verbatim. On a paged
        # request this is the only on-box surface that names WHY paged was
        # not served -- kill switch, kernel preflight, pool capacity, or the
        # resource bundle missing beside the executable (a packaging fault,
        # not a capability one).
        "degrades": degrades,
        "byBatchSize": {
            batch: "+".join(kinds) for batch, kinds in kinds_by_batch.items()
        },
        # Per phase, in the order the wrapper runs them. Makes a mixed-arm run
        # visible in the artifact instead of inferable only from a violation
        # string.
        "byPhase": {
            phase: "+".join(kinds) for phase, kinds in kinds_by_phase.items()
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
            "baseline records no resolved KV backend for its measured "
            "phases; " + NO_COMPARE_HINT
        )
    baseline_by_phase = recorded.get("byPhase")
    if not isinstance(baseline_by_phase, dict) or not baseline_by_phase:
        raise RuntimeError(
            "baseline records no per-phase KV backend, so a baseline whose "
            "scheduler-prefill and arrival phases ran the other backend "
            "would compare clean; " + NO_COMPARE_HINT
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

    # Per phase, for the same reason: the comparison tabulates prefill TTFT
    # and arrival deltas beside the decode curve, and those come from engines
    # this block is the only record of.
    for phase in sorted(set(baseline_by_phase) | set(kv_backend["byPhase"])):
        current = kv_backend["byPhase"].get(phase)
        reference = baseline_by_phase.get(phase)
        if current != reference:
            mismatches.append(f"{phase}: {current!r} (baseline {reference!r})")

    if mismatches:
        raise RuntimeError(
            "KV backend does not match the baseline, so the delta would "
            "compare across backend populations: "
            + ", ".join(mismatches)
            + "; "
            + NO_COMPARE_HINT
        )
