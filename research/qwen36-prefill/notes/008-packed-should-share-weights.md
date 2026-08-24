# 008 — Packed Qwen text SHOULD share expert weights

Status: needs-measure (code fact; runtime fire unknown)

## Code facts

EngineLoopV2 packs equal-length text chunks into one `[B, chunk]`
forward when:

- `packedPrefillSupported` (model + cache bank)
- `CBv2PackedPrefillSteppableModel`
- group size > 1, equal `count` and equal `samples` flag
- NOT (recurrent AND (`hasSpan` OR `positionState != nil`))

Qwen claims `supportsPackedPrefill = true` and
`cbv2SupportsPackedPrefill = true`. Text-only CBv2 requests should
have `positionState == nil` (vision MRoPE sets it). If some serving
path stamps positionState on every Qwen row, packing never fires.

`packedPrefillActivity()` increments only when a rectangular
`B>1` forward actually runs. The installed 0.8.10
`--scheduler-prefill` / `--arrival-invariance` JSON **does not
emit this counter**. We are blind until we add it or log it.

## MoE on a packed tensor

`Qwen35SparseMoeBlock.callAsFunction` routes the whole `x`.
`SwitchGLU.projectExperts` expand-dims + `gatherSort` flattens
leading axes. A `[4, 512, 2048]` hidden becomes one sorted expert
tile over 2048 tokens. Unique experts touched ≈ min(256, assignments).

## The birthday-paradox trap

At L=512, top-8: 4,096 assignments into 256 experts. That already
hits essentially every expert. Packed B=4 at the same L does **not**
reduce the weight stream versus B=1. It only avoids *re-reading*
those weights 4 times.

| Mode | Weight streams per chunk | Activation FLOPs |
|---|---|---|
| 4 solo forwards | 4 × (all experts) | 4× |
| 1 packed `[4,L]` | 1 × (all experts) | 4× |

If 2026-08-19's 4×8K ≈ 1× aggregate was four solo forwards, packing
is a 4× weight-traffic win. If 0.8.6 already packs and only got
+13–17%, we are **activation/L²/GDN-scan bound**, and 2.5× aggregate
will not come from packing.

## What to read off the arrival JSON

If 4-wide 2048 burst aggregate tok/s ≈ 4 × B=1 2048 tok/s → packed
and weight-bound.
If ≈ 1 × B=1 → either packing is off, or we are compute-bound.
If ≈ 1.1–1.3 × B=1 → matches the 0.8.6 claim; packing on, not the 2.5× lever.

Need `packedPrefillActivity` in the harness to distinguish "off" vs
"on but compute-bound."
