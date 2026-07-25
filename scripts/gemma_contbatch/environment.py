"""The performance-relevant process environment: what it is, and how to read it.

The engine ships per-feature kill switches and MLX kernel flags. Flipping one
changes measured throughput without changing a single line of committed code,
so the set of switches in effect is as much a part of "what was measured" as
the model snapshot and the host. This module owns the single definition of
which variables count, so the copy recorded in a report and the copy compared
against a baseline can never diverge.

The set is an explicit allowlist rather than the whole environment: a report
must not leak secrets or paths, and an unrelated variable (PATH, TERM, HOME,
SSH_AUTH_SOCK) must never block a comparison.
"""

from __future__ import annotations

from collections.abc import Mapping


# Variable families that change how tokens are computed or scheduled. A prefix
# is used where the engine exposes a family of related knobs.
#
#   DARKBLOOM_ACTIVATION_RESERVE_  UnifiedMemoryCap activation reserve -> KV headroom
#   DARKBLOOM_CBV2_                continuous-batching v2 scheduler/kernel switches
#                                  (e.g. MIXED_PREFILL_CAP, PAGED_KV, COMPILED, MTP)
#   DARKBLOOM_GEMMA4_              Gemma-4 prefill kernel kill switches
#                                  (PREFILL_TAIL_ROWS, PREFILL_LAST_QUERY, ...)
#   DARKBLOOM_MEM_CAP_             UnifiedMemoryCap fraction -> what fits in memory
#   DARKBLOOM_MTP_                 multi-token prediction / speculative decode
#   DARKBLOOM_PREFIX_CACHE         prefix-cache admission, persistence, and limits
#   MLX_METAL_                     MLX Metal backend behaviour
PERFORMANCE_ENV_PREFIXES = (
    "DARKBLOOM_ACTIVATION_RESERVE_",
    "DARKBLOOM_CBV2_",
    "DARKBLOOM_GEMMA4_",
    "DARKBLOOM_MEM_CAP_",
    "DARKBLOOM_MTP_",
    "DARKBLOOM_PREFIX_CACHE",
    "MLX_METAL_",
)

# Individually named switches that do not share a family prefix. Each one
# selects a different code path through prefill, decode, or the quantized
# expert kernels, so a run with one flipped is not comparable to a run without.
PERFORMANCE_ENV_NAMES = frozenset(
    {
        "DARKBLOOM_ADAPTIVE_PREFILL_ALLOW_8192",
        "DARKBLOOM_B1_GREEDY_FAST_PATH",
        "DARKBLOOM_BF16_CHUNK_MB",
        "DARKBLOOM_BF16_WEIGHTS",
        "DARKBLOOM_COMPILED_DECODE",
        "DARKBLOOM_ENGINE_V2",
        "DARKBLOOM_ENGINE_V2_MODELS",
        "DARKBLOOM_EXPERT_TILES_GATEUP",
        "DARKBLOOM_GEMMA_B1_FAST_PATH",
        "DARKBLOOM_KV_GPTOSS_KERNEL",
        "DARKBLOOM_MLX_MEMORY_RESERVE_GB",
        "MLX_COMPILED_DECODE",
        "MLX_DISABLE_COMPILE",
        "MLX_GATHER_QMM_EXPERT_SLICES",
        "MLX_METALLIB_PATH",
    }
)


def is_performance_variable(name: str) -> bool:
    return name.startswith(PERFORMANCE_ENV_PREFIXES) or name in PERFORMANCE_ENV_NAMES


def performance_environment(environ: Mapping[str, str]) -> dict[str, str]:
    """The allowlisted overrides in effect, sorted for a stable report diff."""
    return {
        key: value
        for key, value in sorted(environ.items())
        if is_performance_variable(key)
    }


def baseline_environment(baseline: Mapping[str, object]) -> dict[str, str] | None:
    """The environment a baseline recorded: `None` when it recorded none.

    `None` means "this baseline predates the environment pin" and is not the
    same as `{}`, which is a positive record of "no overrides were set".
    Malformed shapes raise rather than being coerced -- a pin that cannot be
    read is not a pin.
    """
    metadata = baseline.get("metadata")
    if metadata is None:
        return None
    if not isinstance(metadata, dict):
        raise RuntimeError("baseline metadata is not a JSON object")
    if "environment" not in metadata:
        return None
    environment = metadata["environment"]
    if not isinstance(environment, dict):
        raise RuntimeError("baseline metadata.environment is not a JSON object")
    invalid = sorted(
        str(key)
        for key, value in environment.items()
        if not isinstance(key, str) or not isinstance(value, str)
    )
    if invalid:
        raise RuntimeError(
            "baseline metadata.environment has non-string entries: "
            + ", ".join(invalid)
        )
    return dict(environment)
