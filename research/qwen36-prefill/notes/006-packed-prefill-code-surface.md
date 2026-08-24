# 006 — Packed prefill code surface (local, pre-runtime)

Status: needs-measure

`libs/mlx-swift-lm` @ `ab73a827`.

Capability claim:

- `Libraries/MLXLLM/Models/Qwen35.swift:215` sets
  `capabilities.supportsPackedPrefill = true`
- `Libraries/MLXLLM/Models/Qwen35.swift:1663+` implements
  `.evaluationOnly` and `.lastPositionLogits` (narrowing seam)

Scheduler / engine:

- `CBv2SchedulerConfig.soloPrefillStripeTokens` — default 2048 in
  `EngineV2Factory+Serving.swift`
- `SchedulerV2.swift` ~288+ solo-stripe gate: **exactly one** live
  text request, no decode row, no waiter, no multimodal
- Packed path tests live in `CBv2PackedPrefillTests.swift`,
  `CBv2PackedPrefillActivityTests.swift`
- `engine.packedPrefillActivity()` is the out-of-module probe

Darkbloom wiring:

- `provider-swift/.../EngineV2Factory+Serving.swift`
  `defaultSoloPrefillStripeTokens = 2048`
- `darkbloom benchmark --scheduler-prefill` and
  `--arrival-invariance` are the harness

Hypothesis to confirm on device: capability true ≠ burst packed.
The 2026-08-19 4×8K=1× number plus a mere +13–17% 0.8.6 claim
suggests packed is either not firing on bursts, or firing and
**not** weight-sharing the expert path (experts still gathered
per-row inside the "packed" forward).

If the latter, the bug is inside Qwen MoE flattening
(`qwen35FlattenMoEInputs`), not the scheduler.
