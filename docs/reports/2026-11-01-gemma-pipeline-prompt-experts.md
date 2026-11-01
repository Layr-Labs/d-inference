# Gemma pipeline prompt experts: one shared dispatch, the same bytes

> Last updated: 2026-11-01

This record covers the change to the registered Gemma 4 stages' prompt expert
blocks: they now share one unsorted dispatch per operation instead of building
one subgraph per prompt token. It gives the equality evidence and synthetic
component timings measured on one Mac. It is not a pair, full-model or
qualification result, and it contains no prompt, endpoint or machine identifier.

## Context

Since 2026-10-23 (`gemma4-bf16-token-expert-reduction-v1` in the exact Gemma
arithmetic receipt) a registered Gemma stage computes every prompt token's
expert block at one token, so that prompt arithmetic is the same on every Apple
GPU generation. The receipt was added because rectangular expert products
select chip-specific kernels. The implementation built that per-token
arithmetic as one subgraph per token: about six launches per token per layer,
or about 180,000 launches for a 2,048-token frame on a 15-layer stage. No
prompt throughput had been measured for it.

## Change

`SwitchGLU.callAndWeightedReduceRows` (mlx-swift-lm) projects all rows of a
frame in one call with their expert assignments kept in row order:

- every (row, expert) pair is still an M=1 gathered product. MLX selects
  `gather_qmv` from the bits, dtype and the N and K widths alone, and its grid
  gives each row its own threadgroups;
- the top-8 weighted reduction keeps its one-row `col_reduce_small` thread
  layout, which depends only on the hidden width.

Each row therefore keeps the bytes of its own one-row call, and the receipt is
unchanged. Gemma's batch-decode rows (`Gemma4BatchDecodeScope`) use the same
call.

## Equality evidence

| Check | Device | Result |
|---|---|---|
| `Gemma4PrefillExpertTests`: whole-layer composition against a one-token expert oracle, 7 to 512 tokens, 4 and 8 bits | CPU | bytes equal; one unsorted expert call |
| Same suite: expert branch against per-token layer calls; decode rows 2, 3 and 8 | CPU | bytes equal |
| `GEMMA4_EXPERT_ROWS_GPU=1`: hidden 768, width 192, 16 experts (the production kernel classes), 1 to 2,048 rows, 4 and 8 bits | M5 Ultra GPU | bytes equal; values finite and nonzero |
| `GEMMA4_EXPERT_ROWS_GPU=production`: hidden 2,816, width 704, 128 experts, 1 to 513 rows | M5 Ultra GPU | bytes equal |
| Sensitivity: the shared call against the earlier sorted rectangular call at 512 and 2,048 rows | M5 Ultra GPU | bytes differ, as expected |

The suites ran in a debug build of `libs/darkbloom-cluster` with the SDK test
file linked in and a source-matched `mlx.metallib` (SHA-256
`5b97893cc20e6e9651edf3284d970488af9a9bdd64820231e95fee760eec70ac`, MLX
`72dffa2d`). Other GPU generations were not run. [INFERENCE] The selection
above should hold on them too: on this route `gather_qmv` takes no architecture
input, and the reduction's threadgroup is 32 by 8 on any GPU whose kernels
hold 256 threads per threadgroup.

## Synthetic timings

One layer with random packed weights at the registered geometry: experts at
4 bits, dense MLP and router at 8 bits. Median of five warm runs, debug Swift
build, on an M5 Ultra that was also serving other GPU work, so the figures
carry contention noise.

| Expert block, 4-bit | 512 tokens | 2,048 tokens |
|---|---:|---:|
| Per-token subgraphs (before) | 74.6 ms | 349.9 ms |
| Shared unsorted dispatch (after) | 9.8 ms | 36.8 ms |
| Sorted rectangle (the prompt path before 2026-10-23) | 1.6 ms | 3.6 ms |

| Dense projections of one sliding layer (q, k, v, o, MLP, router) | 512 tokens | 2,048 tokens |
|---|---:|---:|
| M=1 rows (the registered prompt policy, unchanged) | 12.8 ms | 27.7 ms |
| Rectangle | 3.7 ms | 3.7 ms |

[INFERENCE] For a 15-layer stage and a 2,048-token frame, the projections took
about 5.7 s before and take about 1.0 s after, ignoring attention and norms.
That would lift the stage's projection-bound prompt rate from about 360 to
about 2,000 tokens per second. The M=1 policy still costs about 9x the
rectangle. Closing that gap needs a multi-row `qmv` kernel that keeps qmv's
per-row reduction order.

## Not established

- Pair prompt or decode throughput, both schedules, both rank orders.
- Full-artifact numerical agreement on any chip pair.
- Other GPU generations (M1 to M4) and the release build.

Code: `libs/mlx-swift-lm/Libraries/MLXLMCommon/SwitchLayers.swift`
(`SwitchGLU.callAndWeightedReduceRows`) and
`libs/mlx-swift-lm/Libraries/MLXLLM/Models/Gemma4Text.swift` (`Gemma4Experts`).
Mechanism: [Gemma prompt projection reductions](../architecture/inference.md#gemma-prompt-projection-reductions).
