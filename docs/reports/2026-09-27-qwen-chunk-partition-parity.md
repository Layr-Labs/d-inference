# Qwen chunk-partition parity and chunk-agnostic recurrent capture (2026-09-27)

> Last updated: 2026-09-28 · commit `0bd16a9fa`

**Question.** Does a hybrid recurrent Qwen (GatedDeltaNet + full attention)
reach the same complete-checkpoint state at a prefill boundary whatever chunk
partition the scheduler used below it? The production capture rule
(`CBv2RecurrentCheckpointGeometry.record`) assumed not: it disarmed capture
for the rest of the prompt when the chunk cap changed, when a range was not
cap-aligned, or when a range was ragged. That rule is why Qwen donors kept
coarse checkpoints (the
[hit-rate analysis](2026-09-26-prefix-cache-hit-rate-analysis.md) found the
first 512-token boundary surviving out of a 6,200-token prompt once company
left mid-prompt).

**Method.** Throwaway harness `Tests/MLXLMTests/QwenChunkParityExperimentTests.swift`
on engine branch `exp/qwen-chunk-parity` (`libs/mlx-swift-lm` `cd3b4d4a`;
superproject `exp/qwen-chunk-parity` at `c38412e6f`). It bypasses the disarm
through a loop seam, captures the 4,096-token checkpoint (67 tensors: K/V,
conv, SSM, MTP history) of a 6,200-token prompt under six schedules (uniform
512, uniform 2,048, the 4,096 solo stripe, 2,048 then 512s, 512s then 2,048,
and 512s with decode company), compares the bytes, then restores each
checkpoint into a fresh engine and compares 128-token greedy continuations.
Gates: `DARKBLOOM_LIVE_MLX_TESTS=1`, `DARKBLOOM_QWEN_PARITY_MODEL=<snapshot>`.

## Findings

| Model | Checkpoint state across partitions | Continuation after restore |
|---|---|---|
| Qwen3.5-9B (dense MLP) | Bit-identical at 4,096 under every schedule, with or without decode company | Token-exact under any partition (one cold-run difference at token 124, from timing-adaptive MTP draft depth) |
| Qwen3.6-35B-A3B (MoE) | Layer-0 GDN state identical; divergence starts at layer 1, the first layer fed by an expert MLP whose tile route depends on the chunk token count, and compounds into routing flips | Each restore reproduces its own donor partition's cold run. A cold run already diverges at token 3 by chunk width and at token 9 by decode batch width with identical state |

The uniform-chunk rule guarded a property the dense target has under every
partition and the MoE target never had, even cold. Under production
`maxConcurrentPartialPrefills = 1`, company arriving never changes a striping
request's chunk; the rule bit when company left mid-prompt (512s, then a
2,048 stripe) or under a nil cap, and boundaries such as 2,560 also failed
the `% cap` alignment, so a relaxation had to drop cap alignment entirely and
keep only the 256-token block alignment the routing chain needs.

## Decision and what shipped

Capture is now chunk-agnostic (`CBv2RecurrentCheckpointGeometry.isRecurrentBoundary`):
a recurrent boundary is any contiguous computed-range end inside the prompt
that is a multiple of 256 tokens and query-block aligned (the durable path
skips the prompt end itself, since export needs a token after the
checkpoint; the resident bank keeps that endpoint for the next turn) (or the end of a full
chunk of its own cap, a production no-op that keeps files written under the
old rule valid). Packed rows and preemption still disarm; a ragged range end
is simply not a boundary. The manifest's `chunkSize` is provenance, and every
complete-checkpoint adopter resumes under ordinary chunking. Retention keeps
the first, the deepest boundary at or below the coordinator's fork hint, and
the rolling latest (`CBv2CheckpointRetention`), with a fixed 1,024-token
adjacency drop for every layout. Details:
[prefix-cache.md](../architecture/prefix-cache.md#streamed-complete-checkpoints).

Live runs on real weights with the inline MTP head (provider
`Qwen35CheckpointRetentionLiveTests`, gates
`DARKBLOOM_LIVE_MLX_QWEN35_CHECKPOINT_RETENTION=1` and
`DARKBLOOM_LIVE_MLX_QWEN36_MOE_CHECKPOINT=1`):

| Run | Prompt | Hint | Published boundaries | File bytes | Next turn |
|---|---:|---:|---|---|---|
| Qwen3.5-9B solo stripe | 9,171 | 5,120 | 2,048 / 4,096 / 8,192 | 135.4 / 219.3 / 387.1 MB | restores 8,192; a 4,967-token fork restores 4,096, same text as its cold control |
| Qwen3.5-9B, 8,169-token solo donor (adjacency) | 8,169 | 5,120 | 2,048 / 4,096 / 6,144 | 135.4 / 219.3 / 303.2 MB | the 4,096 target, one 2,048-chunk below the 6,144 latest, is kept |
| Qwen3.5-9B, 6 × 512 then 2,048 chunks (company leaves) | 9,171 | 5,120 | 1,024 / 5,120 / 7,168 (manifest `chunkSize` 512 / 2,048 / 2,048) | 93.5 / 261.2 / 345.1 MB | restores 7,168, same text; warm TTFT 3.1 s vs 13.4 s cold |
| Qwen3.6-35B-A3B solo stripe | 9,171 | 5,120 | 2,048 / 4,096 / 8,192 | 114.7 / 165.1 / 265.7 MB | restores 8,192, same text; warm TTFT 1.0 s vs 6.5 s cold |
| Qwen3.6-35B-A3B mixed chunks | 9,171 | 5,120 | 1,024 / 5,120 / 7,168 | 89.6 / 190.2 / 240.6 MB | no disarm |

The fixture pins the solo stripe at 2,048 tokens; production dense Qwen
stripes at 4,096, where the solo rows publish 4,096 / 8,192 with the first
boundary doubling as the target. Before the change the company-leaves rows
published only what the uniform-chunk rule allowed below the first cap
change, so the 7,168 restore did not exist.

## Through the coordinator

`e2e/exact_cache_recurrent_test.go` (`TestIntegrationExactCacheRecurrentCompanyLeaves`,
opt-in via `DARKBLOOM_EXACT_CACHE_RECURRENT_MODEL`) runs the shape above
through a real coordinator, prompt sidecar, Postgres and a release-built
provider: an 18,438-token prompt is primed once (fleet-novel, the coordinator
sends a 0 repeat hint, the provider settles `skipped_novel`, no holder), sent
again once a second tenant's streamed request has produced its first token
(so the donor's first chunks share the step with a decoding row), the second
tenant is cancelled 12 seconds later while the donor is still prefilling
(the donor's own first streamed token marks the end of its prefill), so the
donor's remaining ranges run solo on the 4,096 stripe, and the prompt is
then repeated. With Qwen thinking disabled so the 16-token answers are
comparable:

| Checkpoint (release provider, paged KV) | Prime, cold | Donor, company cancelled at 12 s | Repeat | Restored |
|---|---:|---:|---:|---:|
| Qwen3.5-9B | 57.7 s | 57.2 s | 5.69 s | 16,896 of 18,438 |
| Qwen3.5-35B-A3B (`qwen3.5-35b-a3b`) | 31.3 s | 32.8 s | 1.93 s | 17,920 of 18,438 |

The restored depth is the last full range end before the ragged tail, at
most one 4,096 stripe below the prompt end; the test allows that and
separately requires more than 8,192 restored tokens, which the earlier
uniform-chunk rule could never reach because it disarmed at the cap switch a
handful of plain chunks in. The wall times are the testbed provider's cold
prefill at its default geometry for a non-catalog ID plus a 16-token answer;
the restore removes all but the tail.

## Coverage by checkpoint

| Served checkpoint | Architecture | Evidence |
|---|---|---|
| `qwen3.5-35b-a3b` (Qwen3.5-35B-A3B) and `qwen3.6-35b-a3b-vl-mtp-mxfp8` (Qwen3.6-35B-A3B) | `qwen3_5_moe`, 40 layers, 256 experts | Live retention runs on both checkpoints (solo and company-leaves shapes); the 3.5 run restores 8,192 on the next turn with identical text, 2.85 s warm against 22.0 s cold; the coordinator-routed run above passes on 3.5-35B |
| Qwen3.5-9B | `qwen3_5`, 24 GDN + 8 attention layers | Live retention runs above and the coordinator-routed run; not a production catalog ID |
| `EigenLabs/Qwen3.8-27B-4bit-mtp` (Qwen3.8-27B) | `qwen3_5`, 48 GDN + 16 attention layers | Not run: the provider gates this build to Apple M5 with NAX (`ModelRuntimeRequirements.qwen38RequiredCapabilities`), and the build machine is an M4 Max. The in-process fixture bypasses that gate and trips the engine's 30-second step watchdog during prefill, which is the gate's reason. Its capture path is the dense `qwen3_5` path the 9B exercises |
| Qwen3.8-Flash-Next (`qwen4_exp`), Nemotron 3.5 Lightning (`nemotron_h`), Bonsai 2 | other recurrent layouts | Shared capture rule and engine oracles only; no live retention run |

## Not changed

- The resident recurrent bank (off in production) captures under the same
  rule and its adopters now also resume under ordinary chunking; the
  scheduler's handling of a forced `recurrentChunkSize` has no producer left
  and can be removed separately.
- MoE output variance by chunk width and by decode batch composition is a
  pre-existing property of the expert-MLP kernel route, not of checkpoints. It
  belongs in the numerics contract as its own note.
