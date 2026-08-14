"""Effective Gemma optimization provenance across benchmark subprocesses."""

from __future__ import annotations

from collections.abc import Mapping


PREFILL_KEY = "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL"
WEIGHTED_KEY = "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT"
SAFE_R1_KEY = "MLX_GATHER_QMM_EXPERT_SLICES"


def validate_gemma_optimizations(value: object, source: str) -> dict:
    if not isinstance(value, Mapping):
        raise RuntimeError(f"{source} did not report effective Gemma optimizations")
    prefill = value.get("prefillLayer18")
    weighted = value.get("weightedR1")
    environment = value.get("environment")
    if not isinstance(prefill, bool) or not isinstance(weighted, bool):
        raise RuntimeError(f"{source} reported malformed Gemma optimization booleans")
    # Safe R1 admits one operator refinement when the route is on: "trust"
    # (descriptor-retract readback skipped). The provider's serving-context
    # projection preserves it, so the recorded posture must too; anything
    # else must still be the exact coupled value.
    safe_r1 = environment.get(SAFE_R1_KEY) if isinstance(environment, Mapping) else None
    allowed_safe_r1 = ("1", "trust") if weighted else ("0",)
    expected_environment = {
        PREFILL_KEY: "18" if prefill else "0",
        WEIGHTED_KEY: "1" if weighted else "0",
        SAFE_R1_KEY: safe_r1 if safe_r1 in allowed_safe_r1 else allowed_safe_r1[0],
    }
    if environment != expected_environment:
        raise RuntimeError(
            f"{source} Gemma environment projection does not match its settings: "
            f"expected {expected_environment}, got {environment!r}"
        )
    return {
        "prefillLayer18": prefill,
        "weightedR1": weighted,
        "environment": expected_environment,
    }


def resolve_gemma_optimizations(raw_outputs: Mapping[str, dict]) -> dict:
    """Require one valid effective posture shared by every benchmark phase."""
    resolved = {
        name: validate_gemma_optimizations(payload.get("gemmaOptimizations"), name)
        for name, payload in raw_outputs.items()
    }
    distinct = {repr(value) for value in resolved.values()}
    if len(distinct) != 1:
        detail = ", ".join(
            f"{name}={value}" for name, value in sorted(resolved.items())
        )
        raise RuntimeError(f"benchmark phases used different Gemma optimizations: {detail}")
    return next(iter(resolved.values()))
