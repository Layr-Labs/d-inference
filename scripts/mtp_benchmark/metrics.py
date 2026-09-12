"""MTP activation and automatic-verifier work evidence checks."""
from __future__ import annotations

from typing import Any

from .constants import LEGACY_M5_INACTIVE_REASON_PREFIX

def observed_bucket(metrics: dict[str, Any], expected: int) -> bool:
    if metrics.get("decodeRowBucket") == expected:
        return True
    return any(
        isinstance(item, dict) and item.get("decodeRowBucket") == expected
        for item in metrics.get("costInputs", [])
    )


def expected_mtp_expectation(expect_inactive: bool) -> dict[str, Any]:
    return {
        "kind": "expected_inactive" if expect_inactive else "active",
        "allowedInactiveReasonValues": [],
        "allowedInactiveReasonPrefixes": (
            [LEGACY_M5_INACTIVE_REASON_PREFIX] if expect_inactive else []
        ),
    }


def inactive_reason_matches(
    metrics: dict[str, Any], expectation: dict[str, Any]
) -> bool:
    reason = metrics.get("inactiveReason")
    if not isinstance(reason, str) or not reason:
        return False
    return reason in expectation["allowedInactiveReasonValues"] or any(
        reason.startswith(prefix)
        for prefix in expectation["allowedInactiveReasonPrefixes"]
    )


def validate_zero_speculative_work(metrics: dict[str, Any], label: str) -> None:
    for field in (
        "rounds",
        "seedRows",
        "proposedTokens",
        "acceptedDraftTokens",
        "committedTokens",
    ):
        if metrics.get(field) != 0:
            raise ValueError(f"{label} reported speculative work in {field}")
    # Target verification with zero claimed rounds is still speculative work.
    # These counters are optional in the schema (inactive metrics omit them),
    # so absence counts as zero.
    for field in (
        "rectangularVerificationRounds",
        "serialVerificationRounds",
    ):
        if metrics.get(field) not in (None, 0):
            raise ValueError(f"{label} reported speculative work in {field}")
    for field in (
        "acceptanceByPosition",
        "conditionalAcceptance",
        "skippedRows",
        "depthSelections",
        "controllerFallbacks",
        "costInputs",
    ):
        if metrics.get(field) not in ([], {}):
            raise ValueError(f"{label} reported speculative work in {field}")
    for field in (
        "totalRoundWallTimeNanos",
        "assistantTimeNanos",
        "targetVerifyTimeNanos",
    ):
        if metrics.get(field) is not None:
            raise ValueError(f"{label} reported speculative timing in {field}")


def automatic_rectangular_cap(metrics: dict[str, Any]) -> int | None:
    if metrics.get("verificationMode") != "automatic":
        return None
    cap = metrics.get("maxAutomaticRectangularTokens")
    if isinstance(cap, int) and not isinstance(cap, bool) and cap >= 0:
        return cap
    return None


def positive_cost_inputs(metrics: dict[str, Any]) -> list[dict[str, Any]]:
    return [
        item
        for item in metrics.get("costInputs", [])
        if isinstance(item, dict)
        and item.get("draftDepth", 0) > 0
        and item.get("sampleCount", 0) > 0
    ]


def positive_costs_within_cap(metrics: dict[str, Any], cap: int) -> bool:
    return all(
        item.get("decodeRowBucket", 0) * (item.get("draftDepth", 0) + 1) <= cap
        for item in positive_cost_inputs(metrics)
    )


def validate_automatic_fixed_fallback(
    metrics: dict[str, Any], batch: int, depth: int, label: str
) -> bool:
    """Mirror MTPBenchmarkRunner.validateAutomaticDepthLimitFallback.

    A fixed depth whose batch * (1 + k) exceeds the automatic cap is clamped
    before seed/draft work: either to a smaller positive depth (rectangular
    rounds without controller cost samples, because cost attribution rejects
    depth-mismatched work) or to certified zero-work target-only chaining.
    """
    cap = automatic_rectangular_cap(metrics)
    if cap is None or batch * (depth + 1) <= cap:
        return False
    selections = metrics.get("depthSelections", {})
    has_positive_depth = any(
        key.isdigit() and int(key) > 0 and count > 0
        for key, count in selections.items()
        if isinstance(key, str) and isinstance(count, int)
    )
    if (
        metrics.get("controllerFallbacks", {}).get("automatic_rectangular_limit", 0) <= 0
        or not positive_costs_within_cap(metrics, cap)
        or metrics.get("serialVerificationRounds", 0) != 0
    ):
        raise ValueError(f"{label} escaped its rectangular limit")
    if has_positive_depth:
        if (
            metrics.get("rounds", 0) <= 0
            or metrics.get("proposedTokens", 0) <= 0
            or metrics.get("rectangularVerificationRounds", 0) <= 0
        ):
            raise ValueError(f"{label} lacks clamped-depth evidence")
        return True
    # Complete zero-work evidence, mirroring the Swift validator field for
    # field: a zero-fit clamp certifies that EXACT canonical fallback
    # occurred, so any speculative array, counter, or timing residue must
    # reject the report.
    if (
        metrics.get("selectedDepth") != 0
        or selections.get("0", 0) <= 0
        or metrics.get("rounds", 0) != 0
        or metrics.get("seedRows", 0) != 0
        or metrics.get("proposedTokens", 0) != 0
        or metrics.get("acceptedDraftTokens", 0) != 0
        or metrics.get("committedTokens", 0) != 0
        or metrics.get("rectangularVerificationRounds", 0) not in (None, 0)
        or metrics.get("acceptanceByPosition") not in ([], None)
        or metrics.get("conditionalAcceptance") not in ([], None)
        or metrics.get("skippedRows") not in ({}, None)
        or metrics.get("costInputs") not in ([], None)
        or metrics.get("totalRoundWallTimeNanos") not in (None, 0)
        or metrics.get("assistantTimeNanos") is not None
        or metrics.get("targetVerifyTimeNanos") is not None
    ):
        raise ValueError(f"{label} reported uncategorized work")
    return True


def validate_automatic_adaptive_within_cap(
    metrics: dict[str, Any], batch: int, label: str
) -> bool:
    """Adaptive drafting cannot be demanded when even depth one exceeds the
    automatic cap at this batch size; any drafting after tail rows drain must
    stay rectangular and inside the cap."""
    cap = automatic_rectangular_cap(metrics)
    if cap is None or batch * 2 <= cap:
        return False
    if (
        not positive_costs_within_cap(metrics, cap)
        or metrics.get("serialVerificationRounds", 0) not in (None, 0)
    ):
        raise ValueError(f"{label} escaped its automatic rectangular limit")
    rounds = metrics.get("rounds", 0)
    if rounds > 0:
        # Drafting after tail rows drained inside the cap: every row-round
        # proposes at least one token and is scored by at least one
        # rectangular batch verification (rounds count per-row finalizes;
        # verifier counters count per-batch passes, so equality is NOT the
        # invariant here).
        if (
            metrics.get("proposedTokens", 0) <= 0
            or (metrics.get("rectangularVerificationRounds") or 0) <= 0
        ):
            raise ValueError(
                f"{label} drafted without rectangular verification evidence")
        return True
    # Zero rounds: nothing may have been proposed, accepted, committed, or
    # verified. Seed steps alone remain legitimate — they are recorded at
    # step launch and a seed's row can terminate before its round runs.
    if (
        metrics.get("proposedTokens", 0) != 0
        or metrics.get("acceptedDraftTokens", 0) != 0
        or metrics.get("committedTokens", 0) != 0
        or metrics.get("rectangularVerificationRounds", 0) not in (None, 0)
        or any(count != 0 for count in metrics.get("acceptanceByPosition", []))
        or any(
            item.get("draftDepth", 0) != 0
            for item in metrics.get("costInputs", [])
            if isinstance(item, dict)
        )
    ):
        raise ValueError(f"{label} reported speculative counters without rounds")
    return True


def validate_case_metrics(
    metrics: dict[str, Any], *, kind: str, width: int | None, batch: int,
    mode: str, expect_inactive: bool, expectation: dict[str, Any],
) -> None:
    skipped = metrics.get("skippedRows", {})
    if skipped:
        raise ValueError(f"case {kind}/{width}/B{batch} reported unapproved skips: {skipped}")
    if kind == "target_only":
        if metrics.get("active") is not False:
            raise ValueError(f"target-only B{batch} reported MTP active")
        validate_zero_speculative_work(metrics, f"target-only B{batch}")
        return
    if kind not in {"fixed", "adaptive"}:
        # The report's case-set check diagnoses unknown modes after row checks.
        return
    label = f"fixed L{width}/B{batch}" if kind == "fixed" else f"adaptive B{batch}"
    if expect_inactive:
        if metrics.get("active") is not False:
            raise ValueError(f"{label} unexpectedly reported MTP active")
        if not inactive_reason_matches(metrics, expectation):
            raise ValueError(f"{label} inactive reason is not allowed")
        validate_zero_speculative_work(metrics, f"{label} expected-inactive")
        return
    if kind == "fixed":
        if metrics.get("active") is not True:
            raise ValueError(f"{label} did not prove activation")
    elif metrics.get("active") is not True or not observed_bucket(metrics, batch):
        raise ValueError(f"{label} did not prove activation/bucket")
    # Production evidence must use the automatic verifier without serial work;
    # raw parity also admits diagnostic serial/rectangular verification.
    if mode != "raw-parity" and (
        metrics.get("verificationMode") != "automatic"
        or metrics.get("serialVerificationRounds", 0) not in (None, 0)
    ):
        raise ValueError(f"{label} production evidence requires the automatic verifier")
    if kind == "fixed":
        depth = width - 1
        if validate_automatic_fixed_fallback(metrics, batch, depth, label):
            return
        if not observed_bucket(metrics, batch):
            raise ValueError(f"{label} did not prove its bucket")
        if metrics.get("depthSelections", {}).get(str(depth), 0) <= 0:
            raise ValueError(f"{label} never selected depth {depth}")
        if depth <= 0:
            return
    elif validate_automatic_adaptive_within_cap(metrics, batch, label):
        return
    if metrics.get("rounds", 0) <= 0 or metrics.get("proposedTokens", 0) <= 0:
        raise ValueError(f"{label} did not draft")
    if kind == "adaptive" and not any(
        int(depth) > 0 and count > 0
        for depth, count in metrics.get("depthSelections", {}).items()
    ):
        raise ValueError(f"{label} never selected nonzero depth")
    # Keep the same ordered filters: malformed report values must not bypass a
    # gate merely because another field would reject the sample later.
    if kind == "fixed":
        has_cost = any(
            item.get("decodeRowBucket") == batch and item.get("draftDepth") == depth
            and item.get("sampleCount", 0) > 0
            for item in metrics.get("costInputs", []) if isinstance(item, dict))
        if not has_cost:
            raise ValueError(f"{label} lacks depth/bucket cost evidence")
    else:
        has_cost = any(
            item.get("decodeRowBucket") == batch and item.get("draftDepth", 0) > 0
            and item.get("sampleCount", 0) > 0
            for item in metrics.get("costInputs", []) if isinstance(item, dict))
        if not has_cost:
            raise ValueError(f"{label} lacks positive-depth cost evidence for its requested bucket")

