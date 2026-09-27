# Qwen chunk-partition parity and chunk-agnostic recurrent capture (2026-09-27)

> Last updated: 2026-09-27 · commit `f6321a391`

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
that is a multiple of 256 tokens and query-block aligned (or the end of a full
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

Before the change the second row published only what the uniform-chunk rule
allowed below the first cap change, so the 7,168 restore did not exist.

## Not changed

- The resident recurrent bank still forces a donor's chunk on its adopter
  (`EngineV2.hybridPrefixLookup`); the bank is off in production.
- MoE output variance by chunk width and by decode batch composition is a
  pre-existing property of the expert-MLP kernel route, not of checkpoints. It
  belongs in the numerics contract as its own note.
