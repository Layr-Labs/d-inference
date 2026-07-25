"""Validation that the *delivered* arrival topology was the named one.

The arrival benchmark names its topologies (burst / 25 ms / 100 ms / 250 ms),
but a name only means something if the engine actually received requests on
that schedule. Since arrival `schemaVersion` 2 the benchmark sleeps to absolute
deadlines and reports what it measured, so this module checks the delivered
arrivals and never the requested `arrivalDelaysMs`.

Every check here fails closed. A payload without the measured evidence, a
topology the host could not deliver, a measured offset outside the reported
tolerance, or a reported aggregate that its own rows contradict all abort the
run -- otherwise host scheduling noise is free to be read as an engine
performance change.
"""

from __future__ import annotations

from statistics import median

from .checks import (
    close_enough,
    require_bool,
    require_finite,
    require_non_negative,
    require_non_negative_int,
)
from .config import EXPECTED_ARRIVAL_PATTERNS

STALE_BINARY_HINT = (
    "the arrival payload predates schemaVersion 2 and carries no measured "
    "arrival evidence, so its topology claims cannot be verified; rebuild the "
    "benchmark binary (swift build -c release --product darkbloom) and re-run"
)


def require_field(payload: object, key: str, path: str) -> object:
    """Presence check whose failure names a stale binary, not a bad metric."""
    if not isinstance(payload, dict) or key not in payload:
        raise RuntimeError(f"{path}.{key} is missing: {STALE_BINARY_HINT}")
    return payload[key]


def tightest_requested_gap_ms() -> float:
    """The smallest positive inter-arrival gap any expected topology asks for.

    Mirrors the benchmark's own derivation so a denser future topology tightens
    the bound here too instead of silently outgrowing it.
    """
    gaps = [
        second - first
        for delays in EXPECTED_ARRIVAL_PATTERNS.values()
        for first, second in zip(delays, delays[1:])
        if second - first > 0
    ]
    return float(min(gaps)) if gaps else 25.0


def validate_arrival_bounds(arrival: dict) -> tuple[float, int]:
    """The root tolerance/attempt budget the rest of the checks are read against."""
    tolerance = require_finite(
        require_field(arrival, "arrivalToleranceMs", "arrival"),
        "arrival.arrivalToleranceMs",
    )
    if tolerance <= 0:
        raise RuntimeError(
            f"arrival.arrivalToleranceMs must be positive, got {tolerance}"
        )
    # An unbounded tolerance (via DARKBLOOM_ARRIVAL_TOLERANCE_MS) would let the
    # binary certify any schedule as the named one. Half the tightest gap keeps
    # adjacent rows from ever crossing.
    ceiling = tightest_requested_gap_ms() / 2
    if tolerance > ceiling:
        raise RuntimeError(
            f"arrival tolerance {tolerance:.2f} ms exceeds half the tightest "
            f"requested inter-arrival gap ({ceiling:.2f} ms), so a topology could "
            "be certified that is not the named one; lower "
            "DARKBLOOM_ARRIVAL_TOLERANCE_MS"
        )
    attempts = require_non_negative_int(
        require_field(arrival, "arrivalMaxAttemptsPerSample", "arrival"),
        "arrival.arrivalMaxAttemptsPerSample",
    )
    if attempts < 1:
        raise RuntimeError(
            f"arrival.arrivalMaxAttemptsPerSample must be >= 1, got {attempts}"
        )
    return tolerance, attempts


def validate_row_arrival(name: str, row: dict, delays: list[int], path: str) -> float:
    """Checks one row's measured submission and returns its absolute error."""
    index = int(row["row"])
    scheduled = require_field(row, "scheduledDelayMs", path)
    if scheduled != delays[index]:
        raise RuntimeError(
            f"arrival topology {name} row {index} was scheduled at {scheduled} ms, "
            f"but the topology asks for {delays[index]} ms"
        )
    submitted = require_non_negative(
        require_field(row, "submittedAtMs", path), f"{path}.submittedAtMs"
    )
    error = require_finite(
        require_field(row, "arrivalErrorMs", path), f"{path}.arrivalErrorMs"
    )
    recomputed = submitted - float(delays[index])
    if not close_enough(error, recomputed):
        raise RuntimeError(
            f"arrival topology {name} row {index} reported arrivalErrorMs "
            f"{error} ms, but submittedAtMs {submitted} ms against the requested "
            f"{delays[index]} ms implies {recomputed}"
        )
    return abs(error)


def validate_sample_arrival(
    name: str,
    sample: dict,
    sample_index: int,
    delays: list[int],
    max_attempts: int,
) -> float:
    """Checks one iteration's arrival evidence and returns its worst error."""
    path = f"arrival.{name}[{sample_index}]"
    iteration = sample.get("iteration")
    discarded = require_non_negative_int(
        require_field(sample, "discardedAttempts", path), f"{path}.discardedAttempts"
    )
    if discarded > max_attempts - 1:
        raise RuntimeError(
            f"arrival topology {name} iteration {iteration} reports {discarded} "
            f"discarded attempt(s), which the {max_attempts}-attempt budget cannot "
            "produce"
        )
    reported = require_non_negative(
        require_field(sample, "maxArrivalErrorMs", path), f"{path}.maxArrivalErrorMs"
    )
    worst = max(
        validate_row_arrival(name, row, delays, f"{path}.row[{row.get('row')}]")
        for row in sample["rows"]
    )
    if not close_enough(reported, worst):
        raise RuntimeError(
            f"arrival topology {name} iteration {iteration} reported "
            f"maxArrivalErrorMs {reported:.4f} ms, but its rows show {worst:.4f} ms"
        )
    return reported


def validate_measured_offsets(
    name: str, pattern: dict, delays: list[int], tolerance: float
) -> None:
    """Each per-row median submission must land on the requested offset."""
    path = f"arrival.{name}"
    offsets = require_field(pattern, "measuredArrivalOffsetsMs", path)
    if not isinstance(offsets, list) or len(offsets) != len(delays):
        raise RuntimeError(
            f"arrival topology {name} reported measured arrival offsets "
            f"{offsets!r} for {len(delays)} rows"
        )
    samples = pattern["samples"]
    for index, (measured, requested) in enumerate(zip(offsets, delays)):
        offset = require_non_negative(
            measured, f"{path}.measuredArrivalOffsetsMs[{index}]"
        )
        recomputed = median(
            row["submittedAtMs"]
            for sample in samples
            for row in sample["rows"]
            if int(row["row"]) == index
        )
        if not close_enough(offset, recomputed):
            raise RuntimeError(
                f"arrival topology {name} reported a measured offset of "
                f"{offset} ms for row {index}, but its samples median "
                f"{recomputed} ms"
            )
        drift = offset - float(requested)
        if abs(drift) > tolerance:
            raise RuntimeError(
                f"arrival topology {name} row {index} was delivered at "
                f"{offset:.2f} ms, {drift:+.2f} ms from the requested {requested} ms "
                f"offset (tolerance {tolerance:.2f} ms); the measured topology is "
                "not the named one"
            )


def validate_pattern_arrival(
    name: str,
    pattern: dict,
    delays: list[int],
    tolerance: float,
    max_attempts: int,
) -> None:
    """Full delivered-topology check for one arrival pattern."""
    path = f"arrival.{name}"
    worst = max(
        validate_sample_arrival(name, sample, index, delays, max_attempts)
        for index, sample in enumerate(pattern["samples"])
    )
    reported = require_non_negative(
        require_field(pattern, "maxArrivalErrorMs", path), f"{path}.maxArrivalErrorMs"
    )
    if not close_enough(reported, worst):
        raise RuntimeError(
            f"arrival topology {name} reported maxArrivalErrorMs {reported:.4f} ms, "
            f"but its iterations show {worst:.4f} ms"
        )
    within = require_bool(
        require_field(pattern, "arrivalWithinTolerance", path),
        f"{path}.arrivalWithinTolerance",
    )
    if within and reported > tolerance:
        raise RuntimeError(
            f"arrival topology {name} claims arrivalWithinTolerance with a worst "
            f"arrival error of {reported:.2f} ms, above the {tolerance:.2f} ms "
            "tolerance it was measured against"
        )
    if not within:
        raise RuntimeError(
            f"arrival topology {name} was not delivered within {tolerance:.2f} ms "
            f"(worst measured arrival error {reported:.2f} ms); host scheduling, "
            "not the engine, shaped this run"
        )
    validate_measured_offsets(name, pattern, delays, tolerance)
