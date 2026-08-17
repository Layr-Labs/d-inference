"""Synthetic `darkbloom benchmark` payloads for the wrapper tests.

The real benchmark needs release weights and a Metal GPU, so the wrapper is
exercised against payloads shaped exactly like the ones the binary emits --
complete enough to satisfy every fail-closed validator in the package. A
fixture that only satisfied the checks under test would let the others rot.
"""

from __future__ import annotations

import copy

from statistics import median

from ..config import EXPECTED_ARRIVAL_PATTERNS


HARDWARE = {
    "chipName": "Apple M4 Max",
    "memoryGb": 128,
    "gpuCores": 40,
    "memoryBandwidthGbs": 546,
}
MODEL_ID = "mlx-community/gemma-4-26B-A4B-it-qat-4bit"
MODEL_PATH = "/models/hub/models--mlx-community--gemma/snapshots/abc123"
GEMMA_OPTIMIZATIONS = {
    "prefillLayer18": True,
    "weightedR1": True,
    "environment": {
        "DARKBLOOM_GEMMA4_PREFILL_CHUNK_EVAL": "18",
        "MLX_GEMMA4_FUSED_WEIGHTED_UNSORT": "1",
        "MLX_GATHER_QMM_EXPERT_SLICES": "1",
    },
}


def sweep_payload(
    *,
    prefill_lengths: list[int],
    batch_sizes: list[int],
    iterations: int,
    decode_tokens: int,
    selection: str = "paged",
    resolved: str = "paged",
    resolved_by_batch: dict[int, str] | None = None,
    unmeasured: list[dict] | None = None,
) -> dict:
    """A `--sweep` report.

    `selection` is what was ASKED FOR (and may be "auto", which is never a
    resolved kind); `resolved` is what every cell built unless
    `resolved_by_batch` overrides it per batch size.
    """
    resolved_by_batch = resolved_by_batch or {}
    prefill = [
        {
            "promptTokens": length,
            "prefillTokensPerSecond": 900.0 + length,
            "elapsedMs": 100.0 + length,
        }
        for length in prefill_lengths
        for _ in range(iterations)
    ]
    decode = []
    seen: list[str] = []
    for _ in range(iterations):
        for batch in batch_sizes:
            descriptor = resolved_by_batch.get(batch, resolved)
            if descriptor not in seen:
                seen.append(descriptor)
            # elapsedMs is pinned to the aggregate rate so `validate_decode`'s
            # token-count recomputation holds exactly.
            aggregate = 20.0 * batch
            decode.append(
                {
                    "batchSize": batch,
                    "decodeTokensPerSequence": decode_tokens,
                    "aggregateTokensPerSecond": aggregate,
                    "perSequenceTokensPerSecond": aggregate / batch,
                    "elapsedMs": batch * decode_tokens / aggregate * 1000.0,
                    "resolvedKVBackend": descriptor,
                }
            )
    return {
        "schemaVersion": 5,
        "modelID": MODEL_ID,
        "modelPath": MODEL_PATH,
        "hardware": dict(HARDWARE),
        "gemmaOptimizations": copy.deepcopy(GEMMA_OPTIMIZATIONS),
        "prefill": prefill,
        "decode": decode,
        "derived": {
            "regime": "dense",
            "impliedReadFractionOfWeights": 0.98,
            "decodeTokensPerSecondAtB1": 20.0,
        },
        "notes": [f"kv backend: selection={selection}, resolved={' + '.join(seen)}"],
        "kvBackend": {"selection": selection, "resolved": seen},
        "decodeCoverage": {
            "requestedBatchSizes": sorted(batch_sizes),
            "unmeasured": list(unmeasured or []),
        },
    }


def scheduler_payload(
    *,
    prefill_lengths: list[int],
    iterations: int,
    selection: str = "paged",
    resolved: str = "paged",
) -> dict:
    """A `--scheduler-prefill` report.

    Every measurement builds its own engine, so the backend is recorded per
    sample and de-duplicated into the phase's `kvBackend` block, exactly as
    the binary emits it.
    """
    return {
        "schemaVersion": 3,
        "modelID": MODEL_ID,
        "modelPath": MODEL_PATH,
        "gemmaOptimizations": copy.deepcopy(GEMMA_OPTIMIZATIONS),
        "kvBackend": {"selection": selection, "resolved": [resolved]},
        "samples": [
            {
                "promptTokens": length,
                "iteration": iteration,
                "ttftMs": 50.0 + length,
                "msPerPrefillToken": (50.0 + length) / length,
                "activeMemoryBeforeBytes": 20_000_000_000,
                "peakMemoryBytes": 21_000_000_000,
                "transientPeakBytes": 1_000_000_000,
                "resolvedKVBackend": resolved,
            }
            for length in prefill_lengths
            for iteration in range(1, iterations + 1)
        ],
    }


def arrival_payload(
    *,
    iterations: int,
    prompt_tokens: int,
    decode_tokens: int,
    selection: str = "paged",
    resolved: str = "paged",
) -> dict:
    tolerance = 5.0
    patterns = []
    for name, delays in EXPECTED_ARRIVAL_PATTERNS.items():
        samples = []
        for iteration in range(1, iterations + 1):
            rows = [
                {
                    "row": index,
                    "generatedTokens": decode_tokens,
                    "ttftMs": 40.0 + 10 * index,
                    "decodeTokensPerSecond": 18.0 + index,
                    "completedAtMs": 1000.0 + delay,
                    "tokenChecksum": f"row-{index}",
                    "scheduledDelayMs": delay,
                    # Delivered exactly on the requested offset, so the
                    # measured-topology checks pass without slack.
                    "submittedAtMs": float(delay),
                    "arrivalErrorMs": 0.0,
                }
                for index, delay in enumerate(delays)
            ]
            samples.append(
                {
                    "iteration": iteration,
                    "rows": rows,
                    "aggregateDecodeTokensPerSecond": 72.0,
                    "endToEndTokensPerSecond": 60.0,
                    "makespanMs": 4000.0,
                    "maxArrivalErrorMs": 0.0,
                    "discardedAttempts": 0,
                }
            )
        all_rows = [row for sample in samples for row in sample["rows"]]
        patterns.append(
            {
                "name": name,
                "arrivalDelaysMs": list(delays),
                "outputsStableAcrossIterations": True,
                "outputsMatchBurst": True,
                "samples": samples,
                "medianTTFTMs": median(row["ttftMs"] for row in all_rows),
                "medianPerRequestDecodeTokensPerSecond": median(
                    row["decodeTokensPerSecond"] for row in all_rows
                ),
                "medianAggregateDecodeTokensPerSecond": 72.0,
                "medianEndToEndTokensPerSecond": 60.0,
                "medianMakespanMs": 4000.0,
                "measuredArrivalOffsetsMs": [float(delay) for delay in delays],
                "maxArrivalErrorMs": 0.0,
                "arrivalWithinTolerance": True,
            }
        )
    return {
        "modelID": MODEL_ID,
        "modelPath": MODEL_PATH,
        "schemaVersion": 4,
        "gemmaOptimizations": copy.deepcopy(GEMMA_OPTIMIZATIONS),
        "kvBackend": {"selection": selection, "resolved": [resolved]},
        "promptTokensPerRequest": prompt_tokens,
        "decodeTokensPerRequest": decode_tokens,
        "arrivalToleranceMs": tolerance,
        "arrivalMaxAttemptsPerSample": 3,
        "patterns": patterns,
    }
