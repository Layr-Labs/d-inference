# 002 — Prior art: killed and kept

Status: kept (do not re-run dead rows)

Sources: `docs/reports/2026-08-19-solo-prefill-stripe-experiment.md`,
`docs/reports/2026-08-21-qwen-prefill-retained-optimizations.md`,
`ProviderCore.swift` 0.8.5–0.8.9 comments.

## Kept / shipped (0.8.6 defaults, still in 0.8.10)

- E=256 expert-tile prefill + trust default
- Solo prefill stripe 2048 (env `DARKBLOOM_CBV2_SOLO_PREFILL_STRIPE`)
- Qwen prompt / LM-head narrowing (`.evaluationOnly` / `.lastPositionLogits`)
- Packed prefill *capability* on Qwen (`supportsPackedPrefill = true`)
- Fused gate_up (shipped; do not confuse with the later dead fusion)

Claimed 0.8.6 vs 0.8.5: 8K cold −27.6% (~1,766 tok/s, +38%); 4×8K
aggregate +13–17%. **Re-measure on this M3 Max. Do not inherit M4
numbers as this baseline.**

## Rolled back (0.8.9)

- GDN 4-in-1 input projection fusion (prefill 6–10% TTFT; decode hurt)
- Direct weighted expert unsort reduction (primitive 1.79x; decode hurt)

These are not "dead physics." They are "dead as unguarded defaults."
Revisit only with a decode + uptime A/B on this Mac.

## Dead

| Idea | Evidence |
|---|---|
| MoE mega-kernel | Destroyed down-proj column parallelism |
| GateUp+SwiGLU two-acc FP32 | 1.80 → 3.08 ms, +71% |
| GateUp+SwiGLU bf16-staged | 1.83 → 2.98 ms, +64% |
| Router + shared-expert gate fusion | +1.8% slower at 8K; <1% at 16/32K |

## Unqualified

- D=256 Steel attention: numeric OK, no stable-power speed A/B
- Wavefront / concurrent encode: identified, not built
- GDN chunkwise-parallel scan: estimated 5–7%, needs tolerance parity
- Sparse full-attn >=32K: probe-gated, not 8K

## Policy ≠ throughput

`maxConcurrentPartialPrefills` / FCFS-lean halves **mean TTFT** at
the same aggregate. Do not log it as a 2.5x win.
